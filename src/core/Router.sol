// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { IV3SwapRouter } from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import { ITrancheMarket } from "../interfaces/ITrancheMarket.sol";
import { IRouter } from "../interfaces/IRouter.sol";
import { Errors } from "../errors/Errors.sol";

/**
 * @title Router
 * @notice Router for trading tranche tokens via Uniswap V3 UA/SR pool
 * @dev Senior operations use direct swaps. Junior operations use flash swaps
 *      since no JR liquidity pool exists - borrow SR, recombine/tranche, repay.
 */
contract Router is IRouter, IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    // ============ Enums ============

    /// @notice Operation types for flash swap callbacks
    enum SwapOperation {
        BUY_JUNIOR,
        SELL_JUNIOR,
        SWAP_JUNIOR_TO_SENIOR,
        SWAP_SENIOR_TO_JUNIOR
    }

    // ============ Immutables ============

    /// @notice Uniswap V3 Swap Router
    IV3SwapRouter public immutable swapRouter;

    /// @notice TrancheMarket contract
    ITrancheMarket public immutable trancheMarket;

    /// @notice Uniswap V3 Pool address (UA/srToken)
    IUniswapV3Pool public immutable uniswapPool;

    /// @notice Uniswap V3 pool fee tier (e.g., 3000 = 0.3%)
    uint24 public immutable poolFee;

    /// @notice Transient flag to verify callback originates from this contract's swap
    bool private transient _swapInitiated;

    /// @notice Transient storage for the pool expected to call back
    address private transient _expectedCallbackPool;

    // ============ Modifiers ============

    /// @notice Ensures transaction is executed before deadline
    modifier checkDeadline(uint256 deadline) {
        if (deadline < block.timestamp) revert RouterDeadlineExpired();
        _;
    }

    /// @notice Sets flag to authorize the Uniswap callback
    modifier initiateSwap() {
        _swapInitiated = true;
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Creates a new Router contract
     * @param _swapRouter Uniswap V3 SwapRouter address
     * @param _trancheMarket TrancheMarket contract address
     * @param _uniswapPool Uniswap V3 Pool address (UA/srToken)
     * @param _poolFee Uniswap V3 pool fee tier (e.g., 3000 for 0.3%)
     */
    constructor(address _swapRouter, address _trancheMarket, address _uniswapPool, uint24 _poolFee) {
        if (_swapRouter == address(0) || _trancheMarket == address(0) || _uniswapPool == address(0)) {
            revert Errors.ZeroAddress();
        }

        swapRouter = IV3SwapRouter(_swapRouter);
        trancheMarket = ITrancheMarket(_trancheMarket);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        poolFee = _poolFee;
    }

    // ============ Core Functions ============

    /**
     * @notice Buy senior tranche tokens by depositing UA
     * @dev Swap UA for srToken on Uniswap V3 pool
     * @param uaIn Amount of UA to deposit
     * @param minSrOut Minimum amount of senior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return srOut Amount of senior tokens received
     */
    function buySenior(
        uint256 uaIn,
        uint256 minSrOut,
        uint256 deadline
    ) external override checkDeadline(deadline) returns (uint256 srOut) {
        if (uaIn == 0) revert Errors.TrancheZeroAmount();

        (address uaAddress, address srAddress, ) = trancheMarket.getSwapParameters();

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
     * @param srIn Amount of senior tokens to sell
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return uaOut Amount of UA received
     */
    function sellSenior(
        uint256 srIn,
        uint256 minUaOut,
        uint256 deadline
    ) external override checkDeadline(deadline) returns (uint256 uaOut) {
        if (srIn == 0) revert Errors.TrancheZeroAmount();

        (address uaAddress, address srAddress, ) = trancheMarket.getSwapParameters();

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
     * @dev Flash swap strategy:
     *      1. Transfer UA from user
     *      2. Initiate flash swap to borrow UA from Uniswap pool
     *      3. In callback: Tranche (user UA + borrowed UA) into Senior + Junior
     *      4. In callback: Swap Senior tokens for UA to repay flash loan
     *      5. In callback: Send Junior tokens to user
     * @param uaIn Amount of UA to deposit
     * @param minJrOut Minimum amount of junior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @param flashLoanPool Pool to borrow UA from (address(0) = default UA/SR pool)
     * @param flashLoanToken Paired token in the flash loan pool (address(0) = srToken)
     */
    function buyJunior(
        uint256 uaIn,
        uint256 minJrOut,
        uint256 deadline,
        address flashLoanPool,
        address flashLoanToken
    ) external override checkDeadline(deadline) initiateSwap {
        if (uaIn == 0) revert Errors.TrancheZeroAmount();

        (address uaAddress, address srAddress, ) = trancheMarket.getSwapParameters();

        // Transfer user's UA to contract
        IERC20(uaAddress).safeTransferFrom(msg.sender, address(this), uaIn);

        // Calculate UA to borrow: we need enough to tranche and get SR to repay
        (uint256 expectedSrOut, ) = trancheMarket.previewTranche(uaIn);
        uint256 uaToBorrow = calculateUnderlyingNeeded(expectedSrOut);

        // Determine which pool and token to use for flash loan
        IUniswapV3Pool targetPool = flashLoanPool == address(0)
            ? uniswapPool
            : IUniswapV3Pool(flashLoanPool);
        address pairedToken = flashLoanToken == address(0) ? srAddress : flashLoanToken;
        
        _expectedCallbackPool = address(targetPool);

        // Initiate flash swap to borrow UA from pool
        bool uaIsToken0 = uaAddress < pairedToken;
        bool zeroForOne = !uaIsToken0;

        bytes memory data = abi.encode(msg.sender, uaIn, minJrOut, SwapOperation.BUY_JUNIOR);

        targetPool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(uaToBorrow),
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            data: data
        });
    }

    /**
     * @notice Sell junior tranche tokens for UA using flash swap
     * @dev Flash swap strategy:
     *      1. Transfer junior tokens from user
     *      2. Initiate flash swap to borrow SR tokens from Uniswap pool
     *      3. In callback: Redeem SR + JR for UA via TrancheMarket
     *      4. In callback: Repay pool with the UA owed
     *      5. In callback: Send remaining UA profit to user
     * @param jrIn Amount of junior tokens to sell
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function sellJunior(
        uint256 jrIn,
        uint256 minUaOut,
        uint256 deadline
    ) external override checkDeadline(deadline) initiateSwap {
        if (jrIn == 0) revert Errors.TrancheZeroAmount();

        (address uaAddress, address srAddress, address jrAddress) = trancheMarket.getSwapParameters();

        // Transfer user's JR to contract
        IERC20(jrAddress).safeTransferFrom(msg.sender, address(this), jrIn);

        // Calculate SR needed to match JR for recombination
        uint256 srNeeded = calculateSeniorNeeded(jrIn);

        // Initiate flash swap to borrow SR from pool
        bool zeroForOne = uaAddress < srAddress;
        bytes memory data = abi.encode(msg.sender, jrIn, minUaOut, SwapOperation.SELL_JUNIOR);

        uniswapPool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(srNeeded),
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            data: data
        });
    }

    /**
     * @notice Swap junior tranche tokens for senior tranche tokens
     * @dev Flash swap strategy:
     *      1. Transfer junior tokens from user
     *      2. Initiate flash swap to borrow SR tokens from Uniswap pool
     *      3. In callback: Redeem SR + JR for UA via TrancheMarket
     *      4. In callback: Swap all UA for SR tokens
     *      5. In callback: Repay borrowed SR to pool
     *      6. In callback: Send remaining SR to user
     * @param jrIn Amount of junior tokens to swap
     * @param minSrOut Minimum amount of senior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     */
    function swapJuniorToSenior(
        uint256 jrIn,
        uint256 minSrOut,
        uint256 deadline
    ) external override checkDeadline(deadline) initiateSwap {
        if (jrIn == 0) revert Errors.TrancheZeroAmount();

        (address uaAddress, address srAddress, address jrAddress) = trancheMarket.getSwapParameters();

        // Transfer user's JR to contract
        IERC20(jrAddress).safeTransferFrom(msg.sender, address(this), jrIn);

        // Calculate SR needed to match JR for recombination
        uint256 srNeeded = calculateSeniorNeeded(jrIn);

        // Initiate flash swap to borrow SR from pool
        bool zeroForOne = uaAddress < srAddress;
        bytes memory data = abi.encode(msg.sender, jrIn, minSrOut, SwapOperation.SWAP_JUNIOR_TO_SENIOR);

        uniswapPool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(srNeeded),
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            data: data
        });
    }

    /**
     * @notice Swap senior tranche tokens for junior tranche tokens
     * @dev Flash swap strategy:
     *      1. Transfer senior tokens from user
     *      2. Initiate flash swap to borrow UA from Uniswap pool
     *      3. In callback: Tranche borrowed UA into SR + JR
     *      4. In callback: Sell (user SR + minted SR) for UA to repay flash loan
     *      5. In callback: Send minted JR to user
     * @param srIn Amount of senior tokens to swap
     * @param minJrOut Minimum amount of junior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @param flashLoanPool Pool to borrow UA from (address(0) = default UA/SR pool)
     * @param flashLoanToken Paired token in the flash loan pool (address(0) = srToken)
     */
    function swapSeniorToJunior(
        uint256 srIn,
        uint256 minJrOut,
        uint256 deadline,
        address flashLoanPool,
        address flashLoanToken
    ) external override checkDeadline(deadline) initiateSwap {
        if (srIn == 0) revert Errors.TrancheZeroAmount();

        (address uaAddress, address srAddress, ) = trancheMarket.getSwapParameters();

        // Transfer user's SR to contract
        IERC20(srAddress).safeTransferFrom(msg.sender, address(this), srIn);

        // Calculate UA to borrow
        uint256 uaToBorrow = calculateUnderlyingNeeded(srIn);

        // Determine which pool and token to use for flash loan
        IUniswapV3Pool targetPool = flashLoanPool == address(0)
            ? uniswapPool
            : IUniswapV3Pool(flashLoanPool);
        address pairedToken = flashLoanToken == address(0) ? srAddress : flashLoanToken;
        _expectedCallbackPool = address(targetPool);

        // Initiate flash swap to borrow UA from pool
        bool uaIsToken0 = uaAddress < pairedToken;
        bool zeroForOne = !uaIsToken0;

        bytes memory data = abi.encode(msg.sender, srIn, minJrOut, SwapOperation.SWAP_SENIOR_TO_JUNIOR);

        targetPool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(uaToBorrow),
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            data: data
        });
    }

    /**
     * @notice Uniswap V3 callback function for flash swaps
     * @dev Called by Uniswap pool during swap execution
     * @param amount0Delta Amount of token0 (positive = owe, negative = received)
     * @param amount1Delta Amount of token1 (positive = owe, negative = received)
     * @param data Encoded callback data
     */
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        address expectedPool = _expectedCallbackPool == address(0) ? address(uniswapPool) : _expectedCallbackPool;
        if (msg.sender != expectedPool || !_swapInitiated) revert RouterUnauthorizedCallback();
        _swapInitiated = false;
        _expectedCallbackPool = address(0);

        (address user, uint256 amount, uint256 minOut, SwapOperation operation) = abi.decode(
            data,
            (address, uint256, uint256, SwapOperation)
        );

        (address uaAddress, address srAddress, address jrAddress) = trancheMarket.getSwapParameters();
        bool uaIsToken0 = uaAddress < srAddress;

        if (operation == SwapOperation.SELL_JUNIOR) {
            (uint256 jrIn, uint256 minUaOut) = (amount, minOut);

            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 srBorrowed = uaIsToken0 ? uint256(-amount1Delta) : uint256(-amount0Delta);

            _handleSellJunior(user, jrIn, minUaOut, srBorrowed, uaAddress, srAddress, jrAddress);
        } else if (operation == SwapOperation.BUY_JUNIOR) {
            (uint256 uaIn, uint256 minJrOut) = (amount, minOut);

            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 uaBorrowed = uaIsToken0 ? uint256(-amount0Delta) : uint256(-amount1Delta);

            _handleBuyJunior(user, uaIn, minJrOut, uaBorrowed, uaAddress, srAddress, jrAddress);
        } else if (operation == SwapOperation.SWAP_JUNIOR_TO_SENIOR) {
            (uint256 jrIn, uint256 minSrOut) = (amount, minOut);

            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 srBorrowed = uaIsToken0 ? uint256(-amount1Delta) : uint256(-amount0Delta);

            _handleSwapJuniorToSenior(user, jrIn, minSrOut, srBorrowed, uaAddress, srAddress, jrAddress);
        } else if (operation == SwapOperation.SWAP_SENIOR_TO_JUNIOR) {
            (uint256 srIn, uint256 minJrOut) = (amount, minOut);

            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 uaBorrowed = uaIsToken0 ? uint256(-amount0Delta) : uint256(-amount1Delta);

            _handleSwapSeniorToJunior(user, srIn, minJrOut, uaBorrowed, uaAddress, srAddress, jrAddress);
        }
    }

    /**
     * @notice Internal function to handle selling junior tokens
     * @param jrIn junior tokens (received from user earlier)
     * @param srBorrowed srBorrowed senior tokens (received from flash swap)
     * @dev Called from uniswapV3SwapCallback for SELL_JUNIOR operation
     */
    function _handleSellJunior(
        address user,
        uint256 jrIn,
        uint256 minUaOut,
        uint256 srBorrowed,
        address uaAddress,
        address srAddress,
        address jrAddress
    ) internal {
        // Recombine borrowed SR + user's JR into UA
        IERC20(srAddress).forceApprove(address(trancheMarket), srBorrowed);
        IERC20(jrAddress).forceApprove(address(trancheMarket), jrIn);
        
        uint256 uaReceived = trancheMarket.recombine(srBorrowed, jrIn, address(this));

        // Buy SR with UA to repay flash loan
        IERC20(uaAddress).forceApprove(address(swapRouter), uaReceived);

        IV3SwapRouter.ExactOutputSingleParams memory swapParams = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: uaAddress,
            tokenOut: srAddress,
            fee: poolFee,
            recipient: address(this),
            amountOut: srBorrowed,
            amountInMaximum: uaReceived,
            sqrtPriceLimitX96: 0
        });

        uint256 uaSpentOnSwap = swapRouter.exactOutputSingle(swapParams);

        // Send remaining UA profit to user
        uint256 uaToUser = uaReceived - uaSpentOnSwap;
        if (uaToUser < minUaOut) revert InsufficientOutput();

        // Repay flash loan and send UA to user
        IERC20(srAddress).safeTransfer(msg.sender, srBorrowed);
        IERC20(uaAddress).safeTransfer(user, uaToUser);

        emit SellJunior(user, jrIn, uaToUser);
    }

    /**
     * @notice Internal function to handle buying junior tokens via flash swap
     * @param user Address to receive junior tokens
     * @param uaIn UA provided by user (already in contract)
     * @param minJrOut Minimum junior tokens to receive
     * @param uaBorrowed UA borrowed from flash swap
     * @dev Called from uniswapV3SwapCallback for BUY_JUNIOR operation
     */
    function _handleBuyJunior(
        address user,
        uint256 uaIn,
        uint256 minJrOut,
        uint256 uaBorrowed,
        address uaAddress,
        address srAddress,
        address jrAddress
    ) internal {
        // Tranche (user UA + borrowed UA) into SR + JR
        uint256 totalUa = uaIn + uaBorrowed;

        IERC20(uaAddress).forceApprove(address(trancheMarket), totalUa);
        (uint256 srMinted, uint256 jrMinted) = trancheMarket.tranche(totalUa, address(this));

        // Sell SR for UA to repay flash loan
        IERC20(srAddress).forceApprove(address(swapRouter), srMinted);

        IV3SwapRouter.ExactOutputSingleParams memory swapParams = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: srAddress,
            tokenOut: uaAddress,
            fee: poolFee,
            recipient: address(this),
            amountOut: uaBorrowed,
            amountInMaximum: srMinted,
            sqrtPriceLimitX96: 0
        });

        // TODO: dust amount can remain in contract
        swapRouter.exactOutputSingle(swapParams);

        // Repay flash loan and send JR to user
        IERC20(uaAddress).safeTransfer(msg.sender, uaBorrowed);

        if (jrMinted < minJrOut) revert InsufficientOutput();
        IERC20(jrAddress).safeTransfer(user, jrMinted);

        emit BuyJunior(user, uaIn, jrMinted);
    }

    /**
     * @notice Internal function to handle swapping junior tokens to senior tokens via flash swap
     * @param user Address to receive senior tokens
     * @param jrIn Junior tokens provided by user (already in contract)
     * @param minSrOut Minimum senior tokens to receive
     * @param srBorrowed Senior tokens borrowed from flash swap
     * @dev Called from uniswapV3SwapCallback for SWAP_JUNIOR_TO_SENIOR operation
     */
    function _handleSwapJuniorToSenior(
        address user,
        uint256 jrIn,
        uint256 minSrOut,
        uint256 srBorrowed,
        address uaAddress,
        address srAddress,
        address jrAddress
    ) internal {
        // Recombine borrowed SR + user's JR into UA
        IERC20(srAddress).forceApprove(address(trancheMarket), srBorrowed);
        IERC20(jrAddress).forceApprove(address(trancheMarket), jrIn);
       
        uint256 uaReceived = trancheMarket.recombine(srBorrowed, jrIn, address(this));

        // Swap all UA for SR
        IERC20(uaAddress).forceApprove(address(swapRouter), uaReceived);

        IV3SwapRouter.ExactInputSingleParams memory swapParams = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: uaAddress,
            tokenOut: srAddress,
            fee: poolFee,
            recipient: address(this),
            amountIn: uaReceived,
            amountOutMinimum: srBorrowed,
            sqrtPriceLimitX96: 0
        });

        uint256 srReceived = swapRouter.exactInputSingle(swapParams);

        // Repay borrowed SR to pool
        IERC20(srAddress).safeTransfer(msg.sender, srBorrowed);

        // Send remaining SR profit to user
        uint256 srToUser = srReceived - srBorrowed;
        if (srToUser < minSrOut) revert InsufficientOutput();

        IERC20(srAddress).safeTransfer(user, srToUser);

        emit SwapJuniorToSenior(user, jrIn, srToUser);
    }

    /**
     * @notice Internal function to handle swapping senior tokens to junior tokens via flash swap
     */
    function _handleSwapSeniorToJunior(
        address user,
        uint256 srIn,
        uint256 minJrOut,
        uint256 uaBorrowed,
        address uaAddress,
        address srAddress,
        address jrAddress
    ) internal {
        // Tranche borrowed UA into SR + JR
        IERC20(uaAddress).forceApprove(address(trancheMarket), uaBorrowed);
        (uint256 srMinted, uint256 jrMinted) = trancheMarket.tranche(uaBorrowed, address(this));

        // Total SR = user's SR + minted SR
        uint256 totalSr = srIn + srMinted;

        // Sell SR for exactly uaBorrowed UA to repay the flash loan
        IERC20(srAddress).forceApprove(address(swapRouter), totalSr);

        IV3SwapRouter.ExactOutputSingleParams memory swapParams = IV3SwapRouter.ExactOutputSingleParams({
            tokenIn: srAddress,
            tokenOut: uaAddress,
            fee: poolFee,
            recipient: address(this),
            amountOut: uaBorrowed,
            amountInMaximum: totalSr,
            sqrtPriceLimitX96: 0
        });
        
        // TODO: dust amount can remain in contract
        swapRouter.exactOutputSingle(swapParams);

        IERC20(uaAddress).safeTransfer(msg.sender, uaBorrowed);

        if (jrMinted < minJrOut) revert InsufficientOutput();
        IERC20(jrAddress).safeTransfer(user, jrMinted);

        emit SwapSeniorToJunior(user, srIn, jrMinted);
    }

    // ============ View Functions ============

    function calculateSeniorNeeded(uint256 jrAmount) public view override returns (uint256 srNeeded) {
        uint256 seniorRatio = trancheMarket.seniorRatio();
        uint256 juniorRatio = trancheMarket.juniorRatio();
        srNeeded = (jrAmount * seniorRatio) / juniorRatio;
    }

    function calculateUnderlyingNeeded(uint256 srAmount) public view override returns (uint256 uaNeeded) {
        uint256 seniorRatio = trancheMarket.seniorRatio();
        uaNeeded = (srAmount * 1e18) / seniorRatio;
    }
}