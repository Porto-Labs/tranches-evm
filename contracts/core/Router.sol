// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { ITrancheMarket } from "../interfaces/ITrancheMarket.sol";
import { Errors } from "../errors/Errors.sol";

/**
 * @title Router
 * @notice Router contract for buying and selling senior tranche tokens via Uniswap V3
 * @dev Integrates TrancheMarket tokenization with Uniswap V3 liquidity pools
 *      Pool structure: UA/srToken pair on Uniswap V3
 */
contract Router is IUniswapV3SwapCallback {
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
    ISwapRouter public immutable swapRouter;

    /// @notice TrancheMarket contract
    ITrancheMarket public immutable trancheMarket;

    /// @notice Uniswap V3 Pool address (UA/srToken)
    IUniswapV3Pool public immutable uniswapPool;

    // ============ Events ============

    /**
     * @notice Emitted when senior tokens are bought
     * @param buyer Address that bought the tokens
     * @param uaIn Amount of UA deposited
     * @param srOut Amount of senior tokens received
     */
    event BuySenior(address indexed buyer, uint256 uaIn, uint256 srOut);

    /**
     * @notice Emitted when senior tokens are sold
     * @param seller Address that sold the tokens
     * @param srIn Amount of senior tokens sold
     * @param uaOut Amount of UA received
     */
    event SellSenior(address indexed seller, uint256 srIn, uint256 uaOut);

    /**
     * @notice Emitted when junior tokens are sold via flash swap
     * @param seller Address that sold the tokens
     * @param jrIn Amount of junior tokens sold
     * @param uaOut Amount of UA received
     */
    event SellJunior(address indexed seller, uint256 jrIn, uint256 uaOut);

    // ============ Errors ============

    /// @notice Thrown when transaction deadline has passed
    error RouterDeadlineExpired();

    /// @notice Thrown when callback caller is not the Uniswap pool
    error RouterUnauthorizedCallback();

    /// @notice Thrown when output is less than minimum required
    error InsufficientOutput();

    // ============ Constructor ============

    /**
     * @notice Creates a new Router contract
     * @param _swapRouter Uniswap V3 SwapRouter address
     * @param _trancheMarket TrancheMarket contract address
     * @param _uniswapPool Uniswap V3 Pool address (UA/srToken)
     */
    constructor(address _swapRouter, address _trancheMarket, address _uniswapPool) {
        if (_swapRouter == address(0) || _trancheMarket == address(0) || _uniswapPool == address(0)) {
            revert Errors.ZeroAddress();
        }

        swapRouter = ISwapRouter(_swapRouter);
        trancheMarket = ITrancheMarket(_trancheMarket);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
    }

    // ============ Core Functions ============

    /**
     * @notice Buy senior tranche tokens by depositing UA
     * @dev Strategy: Swap UA for srToken on Uniswap V3 pool
     * @param uaIn Amount of UA to deposit
     * @param minSrOut Minimum amount of senior tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return srOut Amount of senior tokens received
     */
    function buySenior(
        uint256 uaIn,
        uint256 minSrOut,
        uint256 deadline
    ) external returns (uint256 srOut) {
        if (uaIn == 0) revert Errors.TrancheZeroAmount();
        if (deadline < block.timestamp) revert RouterDeadlineExpired();

        // Get swap parameters from TrancheMarket
        (address uaAddress, address srAddress, , uint24 fee) = trancheMarket.getSwapParameters();

        // Transfer UA from user to router
        IERC20(uaAddress).safeTransferFrom(msg.sender, address(this), uaIn);

        // Approve SwapRouter to spend UA
        IERC20(uaAddress).forceApprove(address(swapRouter), uaIn);

        // Swap UA for senior tokens on Uniswap V3
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: uaAddress,
            tokenOut: srAddress,
            fee: fee,
            recipient: msg.sender,
            deadline: deadline,
            amountIn: uaIn,
            amountOutMinimum: minSrOut,
            sqrtPriceLimitX96: 0
        });

        srOut = swapRouter.exactInputSingle(params);

        emit BuySenior(msg.sender, uaIn, srOut);
    }

    /**
     * @notice Sell senior tranche tokens for UA
     * @dev Strategy: Swap srToken for UA on Uniswap V3 pool
     * @param srIn Amount of senior tokens to sell
     * @param minUaOut Minimum amount of UA to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return uaOut Amount of UA received
     */
    function sellSenior(
        uint256 srIn,
        uint256 minUaOut,
        uint256 deadline
    ) external returns (uint256 uaOut) {
        if (srIn == 0) revert Errors.TrancheZeroAmount();
        if (deadline < block.timestamp) revert RouterDeadlineExpired();

        // Get swap parameters from TrancheMarket
        (address uaAddress, address srAddress, , uint24 fee) = trancheMarket.getSwapParameters();

        // Transfer senior tokens from user to router
        IERC20(srAddress).safeTransferFrom(msg.sender, address(this), srIn);

        // Approve SwapRouter to spend senior tokens
        IERC20(srAddress).forceApprove(address(swapRouter), srIn);

        // Swap senior tokens for UA on Uniswap V3
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: srAddress,
            tokenOut: uaAddress,
            fee: fee,
            recipient: msg.sender,
            deadline: deadline,
            amountIn: srIn,
            amountOutMinimum: minUaOut,
            sqrtPriceLimitX96: 0
        });

        uaOut = swapRouter.exactInputSingle(params);

        emit SellSenior(msg.sender, srIn, uaOut);
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
    ) external {
        if (jrIn == 0) revert Errors.TrancheZeroAmount();
        if (deadline < block.timestamp) revert RouterDeadlineExpired();

        (address uaAddress, address srAddress, address jrAddress, ) = trancheMarket.getSwapParameters();

        IERC20(jrAddress).safeTransferFrom(msg.sender, address(this), jrIn);

        uint256 srNeeded = calculateSeniorNeeded(jrIn);

        bool zeroForOne = uaAddress < srAddress;
        bytes memory data = abi.encode(msg.sender, jrIn, minUaOut, SwapOperation.SELL_JUNIOR);

        uniswapPool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            amountSpecified: -int256(srNeeded),
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
        if (msg.sender != address(uniswapPool)) revert RouterUnauthorizedCallback();

        (address user, uint256 jrIn, uint256 minUaOut, SwapOperation operation) = abi.decode(
            data,
            (address, uint256, uint256, SwapOperation)
        );

        (address uaAddress, address srAddress, address jrAddress, uint24 fee) = trancheMarket.getSwapParameters();

        bool uaIsToken0 = uaAddress < srAddress;

        // Route to operation handler
        if (operation == SwapOperation.SELL_JUNIOR) {

            // Extract amounts based on token ordering
            // Negative delta = received from pool, positive delta = owe to pool
            uint256 srBorrowed = uaIsToken0 ? uint256(-amount1Delta) : uint256(-amount0Delta);
            uint256 uaOwed = uaIsToken0 ? uint256(amount0Delta) : uint256(amount1Delta);

            _handleSellJunior(user, jrIn, minUaOut, srBorrowed, uaAddress, srAddress, jrAddress, fee);
        } else if (operation == SwapOperation.BUY_JUNIOR) {
            // TODO: Implement buy junior with leverage
            revert("BUY_JUNIOR not implemented yet");
        } else if (operation == SwapOperation.SWAP_JUNIOR_TO_SENIOR) {
            // TODO: Implement junior to senior swap
            revert("SWAP_JUNIOR_TO_SENIOR not implemented yet");
        } else if (operation == SwapOperation.SWAP_SENIOR_TO_JUNIOR) {
            // TODO: Implement senior to junior swap
            revert("SWAP_SENIOR_TO_JUNIOR not implemented yet");
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
        address jrAddress,
        uint24 fee
    ) internal {
        IERC20(srAddress).forceApprove(address(trancheMarket), srBorrowed);
        IERC20(jrAddress).forceApprove(address(trancheMarket), jrIn);

        uint256 uaReceived = trancheMarket.redeemPreMaturity(srBorrowed, jrIn, address(this));

        IERC20(uaAddress).forceApprove(address(swapRouter), uaReceived);

        ISwapRouter.ExactOutputSingleParams memory swapParams = ISwapRouter.ExactOutputSingleParams({
            tokenIn: uaAddress,
            tokenOut: srAddress,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: srBorrowed, // Exact amount of SR we need to return
            amountInMaximum: uaReceived, // Maximum UA we're willing to spend
            sqrtPriceLimitX96: 0
        });

        uint256 uaSpentOnSwap = swapRouter.exactOutputSingle(swapParams);

        uint256 uaToUser = uaReceived - uaSpentOnSwap;
        if (uaToUser < minUaOut) revert InsufficientOutput();

        IERC20(srAddress).safeTransfer(msg.sender, srBorrowed);
        IERC20(uaAddress).safeTransfer(user, uaToUser);

        emit SellJunior(user, jrIn, uaToUser);
    }

    // ============ View Functions ============

    function calculateSeniorNeeded(uint256 jrAmount) public view returns (uint256 srNeeded) {
        uint256 seniorRatio = trancheMarket.seniorRatio();
        uint256 juniorRatio = trancheMarket.juniorRatio();
        srNeeded = (jrAmount * seniorRatio) / juniorRatio;
    }
}
