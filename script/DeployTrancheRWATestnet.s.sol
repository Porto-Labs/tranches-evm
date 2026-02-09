// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { Router } from "src/core/Router.sol";
import { ERC20Mock } from "test/mocks/ERC20Mock.sol";
import { MockChainlinkAggregator } from "test/mocks/MockChainlinkAggregator.sol";

interface IPositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

contract DeployTrancheRWATestnet is Script {
    uint256 constant ONE = 1e18;
    uint256 constant MATURITY = 1 hours; // for test purpose

    uint256 constant SENIOR_RATIO = 0.725e18; // 72.5% Senior & 27.5% Junior
    uint256 constant SENIOR_FLOOR = 0.04e18; // 4% Minimum Floor
    uint256 constant SENIOR_TARGET = 0.06e18; // 6% Target Yield

    uint256 constant INITIAL_PRICE = 1.02e18;

    uint256 constant PRIME_TO_TRANCHE = 5_000_000e18;
    uint256 constant LP_PRIME_AMOUNT = 3_625_000e18;
    uint256 constant LP_SR_AMOUNT = 3_625_000e18;

    uint24 constant POOL_FEE = 3000;

    address constant UNISWAP_V3_POSITION_MANAGER_SEPOLIA = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant UNISWAP_V3_SWAP_ROUTER_SEPOLIA = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant MORPHO_SEPOLIA = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    ERC20Mock public prime;
    MockChainlinkAggregator public oracle;
    TrancheMarket public market;
    Router public router;
    address public uniswapPool;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        _deployTokenAndOracle();
        _deployTrancheMarket();
        _deployRouter();

        // The first liquidity provider is the deployer
        // In real scenario should be authorized market maker
        _liquidityProviderTranche();
        _createUniswapPool();
        _addLiquidity();

        vm.stopBroadcast();

        _logDeployedAddresses();
    }

    function _deployTokenAndOracle() internal {
        console.log("\n=== Deploying PRIME Token and Oracle ===");

        prime = new ERC20Mock("PRIME Token", "PRIME");
        console.log("PRIME Token deployed at:", address(prime));

        oracle = new MockChainlinkAggregator(8, "PRIME / USD");

        // TODO: verify if it works correctly with price in decimal > 8.
        int256 price8Decimals = int256(INITIAL_PRICE / 1e10); // currentPrice = 1.02e8
        oracle.setRoundData(price8Decimals, block.timestamp);

        console.log("Oracle deployed at:", address(oracle));
        console.log("Initial PRIME price: 1.02 USD");
    }

    function _deployTrancheMarket() internal {
        console.log("\n=== Deploying TrancheMarket ===");

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(prime),
            poolFee: POOL_FEE,
            expiry: block.timestamp + MATURITY, // + 1 hour
            seniorRatio: SENIOR_RATIO,
            admin: msg.sender,
            priceFeed: address(oracle),
            seniorFloor: SENIOR_FLOOR,
            seniorTarget: SENIOR_TARGET,
            liquidationEnabled: true,
            liquidationBuffer: 0.025e18, // 2.5%
            liquidationReward: 0.025e18 // 2.5%
        });

        market = new TrancheMarket(params);

        console.log("TrancheMarket deployed at:", address(market));
        console.log("Senior Token (srPRIME):", market.srToken());
        console.log("Junior Token (jrPRIME):", market.jrToken());

        console.log("Maturity:", block.timestamp + MATURITY);
    }

    function _liquidityProviderTranche() internal {
        console.log("\n=== Liquidity Provider Tranche ===");

        uint256 totalPrimeForLP = LP_PRIME_AMOUNT + PRIME_TO_TRANCHE;

        // Mint 8,625,000 PRIME total (5M to tranche + 3.625M for pool)
        // Pool ratio 1:1 -> (3.625M PRIME : 3.625M srPRIME)
        prime.mint(msg.sender, totalPrimeForLP);
        console.log("Minted PRIME to LP:", totalPrimeForLP / 1e18, "PRIME");

        // Tranche 5,000,000 PRIME:
        //     3,625,000 srPRIME (72.5%)
        //     1,375,000 jrPRIME (27.5%)
        prime.approve(address(market), PRIME_TO_TRANCHE);
        (uint256 srOut, uint256 jrOut) = market.tranche(PRIME_TO_TRANCHE, msg.sender);

        console.log("Tranched PRIME:", PRIME_TO_TRANCHE / 1e18);
        console.log("Received srPRIME:", srOut / 1e18);
        console.log("Received jrPRIME:", jrOut / 1e18);
        console.log("PRIME kept for pool:", LP_PRIME_AMOUNT / 1e18);
    }

    function _createUniswapPool() internal {
        console.log("\n=== Creating Uniswap V3 Pool ===");

        IPositionManager positionManager = IPositionManager(UNISWAP_V3_POSITION_MANAGER_SEPOLIA);

        address token0;
        address token1;
        if (address(prime) < market.srToken()) {
            token0 = address(prime);
            token1 = market.srToken();
        } else {
            token0 = market.srToken();
            token1 = address(prime);
        }

        // sqrtPriceX96 = sqrt(price) × 2^96
        // This sets a 1:1 price ratio between token0 and token1 when initializing the pool.
        // Pool ratio 1:1 -> (3.625M PRIME : 3.625M srPRIME)
        //
        // For different price ratios:
        // Price (token1/token0)  |  sqrtPriceX96
        // 0.5                    |  56022770974786139918731938227
        // 1.0                    |  79228162514264337593543950336
        // 2.0                    |  112045541949572279837463876454
        //
        // Since our pool is PRIME/srPRIME at 1:1 ratio, we use 2^96.
        uint160 sqrtPriceX96 = 79_228_162_514_264_337_593_543_950_336;

        uniswapPool = positionManager.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);

        console.log("Uniswap V3 Pool created at:", uniswapPool);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Fee tier: 0.3%");
    }

    function _addLiquidity() internal {
        console.log("\n=== Adding Liquidity to Pool ===");

        IPositionManager positionManager = IPositionManager(UNISWAP_V3_POSITION_MANAGER_SEPOLIA);

        address srToken = market.srToken();

        prime.approve(UNISWAP_V3_POSITION_MANAGER_SEPOLIA, LP_PRIME_AMOUNT);
        IERC20(srToken).approve(UNISWAP_V3_POSITION_MANAGER_SEPOLIA, LP_SR_AMOUNT);

        address token0;
        address token1;
        uint256 amount0Desired;
        uint256 amount1Desired;

        if (address(prime) < srToken) {
            token0 = address(prime);
            token1 = srToken;
            amount0Desired = LP_PRIME_AMOUNT;
            amount1Desired = LP_SR_AMOUNT;
        } else {
            token0 = srToken;
            token1 = address(prime);
            amount0Desired = LP_SR_AMOUNT;
            amount1Desired = LP_PRIME_AMOUNT;
        }

        // liquidity is provided across the entire price curve
        // TODO: adjust ticks for narrower range if needed
        int24 tickLower = -887_220;
        int24 tickUpper = 887_220;

        IPositionManager.MintParams memory params = IPositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            // TODO: Add slippage protection. Since the deployer provides liquidity (as it is now),
            // slippage minimums should be set to prevent front-running before initial liquidity is added.
            // If initial liquidity is provided from external authorized market maker, slippage can be set to 0.
            amount0Min: 0,
            amount1Min: 0,
            recipient: msg.sender,
            deadline: block.timestamp + 1 minutes
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(params);

        console.log("LP Position NFT ID:", tokenId);
        console.log("Liquidity added:", uint256(liquidity));
        console.log("Amount0 used:", amount0 / 1e18);
        console.log("Amount1 used:", amount1 / 1e18);
    }

    function _deployRouter() internal {
        console.log("\n=== Deploying Router ===");

        router = new Router(UNISWAP_V3_SWAP_ROUTER_SEPOLIA, MORPHO_SEPOLIA);

        console.log("Router deployed at:", address(router));
    }

    function _logDeployedAddresses() internal view {
        console.log("\n");
        console.log("========================================");
        console.log("       DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Network: Sepolia Testnet");
        console.log("----------------------------------------");
        console.log("PRIME Token:        ", address(prime));
        console.log("Oracle:             ", address(oracle));
        console.log("TrancheMarket:      ", address(market));
        console.log("Senior Token:       ", market.srToken());
        console.log("Junior Token:       ", market.jrToken());
        console.log("Uniswap Pool:       ", uniswapPool);
        console.log("Router:             ", address(router));
        console.log("----------------------------------------");
        console.log("Maturity timestamp: ", market.expiry());
        console.log("Current timestamp:  ", block.timestamp);
        console.log("Time to maturity:   ", (market.expiry() - block.timestamp) / 60, "minutes");
        console.log("========================================");
        console.log("\n");
        console.log("To update oracle price, call:");
        console.log("oracle.setRoundData(price8Decimals, block.timestamp)");
        console.log("Example prices:");
        console.log("  0.97 USD = 97000000"); // All-Time Low: Dec 07, 2025
        console.log("  1.02 USD = 102000000");
        console.log("  1.10 USD = 110000000");
        console.log("\n");
    }
}
