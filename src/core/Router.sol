// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IV3SwapRouter } from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import { IMorphoBase } from "@morpho-blue/interfaces/IMorpho.sol";
import { IMorphoFlashLoanCallback } from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
import { ITrancheMarket } from "../interfaces/ITrancheMarket.sol";
import { IRouter } from "../interfaces/IRouter.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/**
 * @title Router
 * @notice Router for trading tranche tokens via Uniswap V3 UA/SR pool
 * @dev Senior operations use direct swaps. Junior operations use Morpho flash loans
 *      since no JR liquidity pool exists - borrow tokens, recombine/tranche, repay.
 */
contract Router is IRouter, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    /// @notice Operation types for flash loan callbacks
    enum SwapOperation {
        BUY_JUNIOR,
        SELL_JUNIOR,
        SWAP_JUNIOR_TO_SENIOR,
        SWAP_SENIOR_TO_JUNIOR
    }

    // ============ Immutables ============

    /// @notice Uniswap V3 Swap Router
    IV3SwapRouter public immutable swapRouter;

    /// @notice Morpho Blue contract for flash loans
    IMorphoBase public immutable morpho;

    /// @notice Transient flag to verify callback originates from this contract's flash loan
    bool private transient _flashLoanInitiated;

    // ============ Modifiers ============

    /// @notice Ensures transaction is executed before deadline
    modifier checkDeadline(uint256 deadline) {
        if (deadline < block.timestamp) revert RouterDeadlineExpired();
        _;
    }

    /// @notice Ensures callback is called from Morpho
    modifier onlyMorpho() {
        if (msg.sender != address(morpho)) revert RouterUnauthorizedCallback();
        _;
    }

    /// @notice Sets flag to authorize the Morpho callback
    modifier initiateFlashLoan() {
        _flashLoanInitiated = true;
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Creates a new Router contract
     * @param _swapRouter Uniswap V3 SwapRouter address
     * @param _morpho Morpho Blue contract address
     */
    constructor(address _swapRouter, address _morpho) {
        if (_swapRouter == address(0) || _morpho == address(0)) {
            revert ZeroAddress();
        }

        swapRouter = IV3SwapRouter(_swapRouter);
        morpho = IMorphoBase(_morpho);
    }

    // ============ Core Functions ============

    /**
     * @notice Buy senior tranche tokens by depositing UA
     * @dev Swap UA for srToken on Uniswap V3 pool
     * @param market TrancheMarket contract address
     * @param uaIn Amount of UA to deposit
     * @param minSrOut Minimum amount of senior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return srOut Amount of senior tokens received
     */
    function buySenior(address market, uint256 uaIn, uint256 minSrOut, uint256 deadline)
        external
        override
        checkDeadline(deadline)
        returns (uint256 srOut)
    {
        if (uaIn == 0) revert ZeroAmount();

        (address uaAddress, address srAddress,, uint24 poolFee) = ITrancheMarket(market).getSwapParameters();

        IERC20(uaAddress).safeTransferFrom(msg.sender, address(this), uaIn);

        IERC20(uaAddress).forceApprove(address(swapRouter), uaIn);

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: uaAddress,
            tokenOut: srAddress,
            fee: poolFee,
            recipient: msg.sender,
            amountIn: uaIn,
            amountOutMinimum: minSrOut,
            sqrtPriceLimitX96: 0
        });

        srOut = swapRouter.exactInputSingle(params);

        emit BuySenior(msg.sender, uaIn, srOut);
    }

    /**
     * @notice Sell senior tranche tokens for UA
     * @dev Swap srToken for UA on Uniswap V3 pool
     * @param market TrancheMarket contract address
     * @param srIn Amount of senior tokens to sell
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return uaOut Amount of UA received
     */
    function sellSenior(address market, uint256 srIn, uint256 minUaOut, uint256 deadline)
        external
        override
        checkDeadline(deadline)
        returns (uint256 uaOut)
    {
        if (srIn == 0) revert ZeroAmount();
        (address uaAddress, address srAddress,, uint24 poolFee) = ITrancheMarket(market).getSwapParameters();

        IERC20(srAddress).safeTransferFrom(msg.sender, address(this), srIn);

        IERC20(srAddress).forceApprove(address(swapRouter), srIn);

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: srAddress,
            tokenOut: uaAddress,
            fee: poolFee,
            recipient: msg.sender,
            amountIn: srIn,
            amountOutMinimum: minUaOut,
            sqrtPriceLimitX96: 0
        });

        uaOut = swapRouter.exactInputSingle(params);
        emit SellSenior(msg.sender, srIn, uaOut);
    }

    /**
     * @notice Buy junior tranche tokens by depositing UA
     * @dev Flash loan strategy:
     *      1. Transfer UA from user
     *      2. Borrow additional UA from Morpho flash loan
     *      3. In callback: Tranche (user UA + borrowed UA) into Senior + Junior
     *      4. In callback: Swap Senior tokens for UA to repay flash loan
     *      5. In callback: Send Junior tokens to user
     * @param market TrancheMarket contract address
     * @param uaIn Amount of UA to deposit
     * @param uaToBorrow Amount of UA to borrow from flash loan (calculated off-chain)
     * @param minJrOut Minimum amount of junior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function buyJunior(address market, uint256 uaIn, uint256 uaToBorrow, uint256 minJrOut, uint256 deadline)
        external
        override
        checkDeadline(deadline)
        initiateFlashLoan
    {
        if (uaIn == 0) revert ZeroAmount();
        address uaAddress = ITrancheMarket(market).uaToken();

        IERC20(uaAddress).safeTransferFrom(msg.sender, address(this), uaIn);

        bytes memory data = abi.encode(market, msg.sender, uaIn, minJrOut, SwapOperation.BUY_JUNIOR);

        morpho.flashLoan(uaAddress, uaToBorrow, data);
    }

    /**
     * @notice Sell junior tranche tokens for UA using flash loan
     * @dev Flash loan strategy:
     *      1. Transfer junior tokens from user
     *      2. Borrow UA from Morpho flash loan
     *      3. In callback: Swap UA for SR on Uniswap
     *      4. In callback: Redeem SR + JR for UA via TrancheMarket
     *      5. In callback: Repay borrowed UA to Morpho
     *      6. In callback: Send remaining UA profit to user
     * @param market TrancheMarket contract address
     * @param jrIn Amount of junior tokens to sell
     * @param uaToBorrow Amount of UA to borrow from flash loan (calculated off-chain)
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function sellJunior(address market, uint256 jrIn, uint256 uaToBorrow, uint256 minUaOut, uint256 deadline)
        external
        override
        checkDeadline(deadline)
        initiateFlashLoan
    {
        if (jrIn == 0) revert ZeroAmount();

        (address uaAddress,, address jrAddress,) = ITrancheMarket(market).getSwapParameters();

        IERC20(jrAddress).safeTransferFrom(msg.sender, address(this), jrIn);

        bytes memory data = abi.encode(market, msg.sender, jrIn, minUaOut, SwapOperation.SELL_JUNIOR);

        morpho.flashLoan(uaAddress, uaToBorrow, data);
    }

    /**
     * @notice Swap junior tranche tokens for senior tranche tokens
     * @dev Flash loan strategy:
     *      1. Transfer junior tokens from user
     *      2. Borrow UA from Morpho flash loan
     *      3. In callback: Swap UA for SR on Uniswap
     *      4. In callback: Redeem SR + JR for UA via TrancheMarket
     *      5. In callback: Repay borrowed UA to Morpho
     *      6. In callback: Swap remaining UA for SR
     *      7. In callback: Send SR to user
     * @param market TrancheMarket contract address
     * @param jrIn Amount of junior tokens to swap
     * @param uaToBorrow Amount of UA to borrow from flash loan (calculated off-chain)
     * @param minSrOut Minimum amount of senior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function swapJuniorToSenior(address market, uint256 jrIn, uint256 uaToBorrow, uint256 minSrOut, uint256 deadline)
        external
        override
        checkDeadline(deadline)
        initiateFlashLoan
    {
        if (jrIn == 0) revert ZeroAmount();
        (address uaAddress,, address jrAddress,) = ITrancheMarket(market).getSwapParameters();

        IERC20(jrAddress).safeTransferFrom(msg.sender, address(this), jrIn);

        bytes memory data = abi.encode(market, msg.sender, jrIn, minSrOut, SwapOperation.SWAP_JUNIOR_TO_SENIOR);

        morpho.flashLoan(uaAddress, uaToBorrow, data);
    }

    /**
     * @notice Swap senior tranche tokens for junior tranche tokens
     * @dev Flash loan strategy:
     *      1. Transfer senior tokens from user
     *      2. Borrow UA from Morpho flash loan
     *      3. In callback: Tranche borrowed UA into SR + JR
     *      4. In callback: Sell (user SR + minted SR) for UA to repay flash loan
     *      5. In callback: Send minted JR to user
     * @param market TrancheMarket contract address
     * @param srIn Amount of senior tokens to swap
     * @param uaToBorrow Amount of UA to borrow from flash loan (calculated off-chain)
     * @param minJrOut Minimum amount of junior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function swapSeniorToJunior(address market, uint256 srIn, uint256 uaToBorrow, uint256 minJrOut, uint256 deadline)
        external
        override
        checkDeadline(deadline)
        initiateFlashLoan
    {
        if (srIn == 0) revert ZeroAmount();
        (address uaAddress, address srAddress,,) = ITrancheMarket(market).getSwapParameters();

        IERC20(srAddress).safeTransferFrom(msg.sender, address(this), srIn);

        bytes memory data = abi.encode(market, msg.sender, srIn, minJrOut, SwapOperation.SWAP_SENIOR_TO_JUNIOR);

        morpho.flashLoan(uaAddress, uaToBorrow, data);
    }

    /**
     * @notice Morpho flash loan callback function
     * @dev Called by Morpho during flash loan execution
     * @param assets Amount of ua borrowed
     * @param data Encoded callback data
     */
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external override onlyMorpho {
        if (!_flashLoanInitiated) revert RouterUnauthorizedCallback();
        _flashLoanInitiated = false;

        (address market, address user, uint256 amount, uint256 minOut, SwapOperation operation) =
            abi.decode(data, (address, address, uint256, uint256, SwapOperation));

        if (operation == SwapOperation.SELL_JUNIOR) {
            _handleSellJunior(market, user, amount, minOut, assets);
        } else if (operation == SwapOperation.BUY_JUNIOR) {
            _handleBuyJunior(market, user, amount, minOut, assets);
        } else if (operation == SwapOperation.SWAP_JUNIOR_TO_SENIOR) {
            _handleSwapJuniorToSenior(market, user, amount, minOut, assets);
        } else if (operation == SwapOperation.SWAP_SENIOR_TO_JUNIOR) {
            _handleSwapSeniorToJunior(market, user, amount, minOut, assets);
        }
    }

    /**
     * @notice Internal function to handle selling junior tokens
     * @param market TrancheMarket contract address
     * @param user Address to receive UA
     * @param jrIn Junior tokens (received from user earlier)
     * @param minUaOut Minimum UA to receive
     * @param uaBorrowed UA borrowed from flash loan
     * @dev Called from onMorphoFlashLoan for SELL_JUNIOR operation
     */
    function _handleSellJunior(address market, address user, uint256 jrIn, uint256 minUaOut, uint256 uaBorrowed)
        internal
    {
        (address uaAddress, address srAddress, address jrAddress, uint24 poolFee) =
            ITrancheMarket(market).getSwapParameters();

        uint256 srNeeded = calculateSeniorNeeded(jrIn, market);

        IERC20(uaAddress).forceApprove(address(swapRouter), uaBorrowed);

        IV3SwapRouter.ExactOutputSingleParams memory swapParams = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: uaAddress,
            tokenOut: srAddress,
            fee: poolFee,
            recipient: address(this),
            amountOut: srNeeded,
            amountInMaximum: uaBorrowed,
            sqrtPriceLimitX96: 0
        });

        uint256 uaSpentOnSwap = swapRouter.exactOutputSingle(swapParams);

        IERC20(srAddress).forceApprove(market, srNeeded);
        IERC20(jrAddress).forceApprove(market, jrIn);

        uint256 uaFromRecombine = ITrancheMarket(market).recombine(srNeeded, jrIn, address(this));

        uint256 totalUa = uaFromRecombine + (uaBorrowed - uaSpentOnSwap);
        if (totalUa < uaBorrowed + minUaOut) revert InsufficientOutput();

        IERC20(uaAddress).forceApprove(address(morpho), uaBorrowed);

        uint256 uaToUser = totalUa - uaBorrowed;

        IERC20(uaAddress).safeTransfer(user, uaToUser);

        emit SellJunior(user, jrIn, uaToUser);
    }

    /**
     * @notice Internal function to handle buying junior tokens via flash loan
     * @param market TrancheMarket contract address
     * @param user Address to receive junior tokens
     * @param uaIn UA provided by user (already in contract)
     * @param minJrOut Minimum junior tokens to receive
     * @param uaBorrowed UA borrowed from flash loan
     * @dev Called from onMorphoFlashLoan for BUY_JUNIOR operation
     */
    function _handleBuyJunior(address market, address user, uint256 uaIn, uint256 minJrOut, uint256 uaBorrowed)
        internal
    {
        (address uaAddress, address srAddress, address jrAddress, uint24 poolFee) =
            ITrancheMarket(market).getSwapParameters();

        uint256 totalUa = uaIn + uaBorrowed;

        IERC20(uaAddress).forceApprove(market, totalUa);
        (uint256 srMinted, uint256 jrMinted) = ITrancheMarket(market).tranche(totalUa, address(this));

        IERC20(srAddress).forceApprove(address(swapRouter), srMinted);

        IV3SwapRouter.ExactInputSingleParams memory swapParams = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: srAddress,
            tokenOut: uaAddress,
            fee: poolFee,
            recipient: address(this),
            amountIn: srMinted,
            amountOutMinimum: uaBorrowed,
            sqrtPriceLimitX96: 0
        });

        uint256 uaReceived = swapRouter.exactInputSingle(swapParams);

        if (jrMinted < minJrOut) revert InsufficientOutput();

        IERC20(uaAddress).forceApprove(address(morpho), uaBorrowed);
        IERC20(jrAddress).safeTransfer(user, jrMinted);

        if (uaReceived > uaBorrowed) {
            IERC20(uaAddress).safeTransfer(user, uaReceived - uaBorrowed);
        }

        emit BuyJunior(user, uaIn, jrMinted);
    }

    /**
     * @notice Internal function to handle swapping junior tokens to senior tokens via flash loan
     * @param market TrancheMarket contract address
     * @param user Address to receive senior tokens
     * @param jrIn Junior tokens provided by user (already in contract)
     * @param minSrOut Minimum senior tokens to receive
     * @param uaBorrowed UA borrowed from flash loan
     * @dev Called from onMorphoFlashLoan for SWAP_JUNIOR_TO_SENIOR operation
     */
    function _handleSwapJuniorToSenior(address market, address user, uint256 jrIn, uint256 minSrOut, uint256 uaBorrowed)
        internal
    {
        (address uaAddress, address srAddress, address jrAddress, uint24 poolFee) =
            ITrancheMarket(market).getSwapParameters();

        uint256 remainingUa;
        {
            uint256 srNeeded = calculateSeniorNeeded(jrIn, market);

            IERC20(uaAddress).forceApprove(address(swapRouter), uaBorrowed);

            uint256 uaSpentOnSwap = swapRouter.exactOutputSingle(
                IV3SwapRouter.ExactOutputSingleParams({
                    tokenIn: uaAddress,
                    tokenOut: srAddress,
                    fee: poolFee,
                    recipient: address(this),
                    amountOut: srNeeded,
                    amountInMaximum: uaBorrowed,
                    sqrtPriceLimitX96: 0
                })
            );

            IERC20(srAddress).forceApprove(market, srNeeded);
            IERC20(jrAddress).forceApprove(market, jrIn);

            uint256 uaFromRecombine = ITrancheMarket(market).recombine(srNeeded, jrIn, address(this));

            remainingUa = uaFromRecombine - uaSpentOnSwap;
        }

        IERC20(uaAddress).forceApprove(address(morpho), uaBorrowed);
        IERC20(uaAddress).forceApprove(address(swapRouter), remainingUa);

        uint256 srToUser = swapRouter.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: uaAddress,
                tokenOut: srAddress,
                fee: poolFee,
                recipient: user,
                amountIn: remainingUa,
                amountOutMinimum: minSrOut,
                sqrtPriceLimitX96: 0
            })
        );

        emit SwapJuniorToSenior(user, jrIn, srToUser);
    }

    /**
     * @notice Internal function to handle swapping senior tokens to junior tokens via flash loan
     * @param market TrancheMarket contract address
     * @param user Address to receive junior tokens
     * @param srIn Senior tokens provided by user (already in contract)
     * @param minJrOut Minimum junior tokens to receive
     * @param uaBorrowed UA borrowed from flash loan
     * @dev Called from onMorphoFlashLoan for SWAP_SENIOR_TO_JUNIOR operation
     */
    function _handleSwapSeniorToJunior(address market, address user, uint256 srIn, uint256 minJrOut, uint256 uaBorrowed)
        internal
    {
        (address uaAddress, address srAddress, address jrAddress, uint24 poolFee) =
            ITrancheMarket(market).getSwapParameters();

        IERC20(uaAddress).forceApprove(market, uaBorrowed);
        (uint256 srMinted, uint256 jrMinted) = ITrancheMarket(market).tranche(uaBorrowed, address(this));

        uint256 totalSr = srIn + srMinted;
        IERC20(srAddress).forceApprove(address(swapRouter), totalSr);

        IV3SwapRouter.ExactInputSingleParams memory swapParams = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: srAddress,
            tokenOut: uaAddress,
            fee: poolFee,
            recipient: address(this),
            amountIn: totalSr,
            amountOutMinimum: uaBorrowed,
            sqrtPriceLimitX96: 0
        });

        uint256 uaReceived = swapRouter.exactInputSingle(swapParams);

        if (jrMinted < minJrOut) revert InsufficientOutput();

        IERC20(uaAddress).forceApprove(address(morpho), uaBorrowed);
        IERC20(jrAddress).safeTransfer(user, jrMinted);

        if (uaReceived > uaBorrowed) {
            IERC20(uaAddress).safeTransfer(user, uaReceived - uaBorrowed);
        }

        emit SwapSeniorToJunior(user, srIn, jrMinted);
    }

    // ============ View Functions ============

    function calculateSeniorNeeded(uint256 jrAmount, address market) public view override returns (uint256 srNeeded) {
        uint256 seniorRatio = ITrancheMarket(market).seniorRatio();
        uint256 juniorRatio = ITrancheMarket(market).juniorRatio();
        srNeeded = FixedPointMathLib.fullMulDivUp(jrAmount, seniorRatio, juniorRatio);
    }
}
