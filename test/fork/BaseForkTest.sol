// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { TrancheToken } from "src/core/TrancheToken.sol";
import { Router } from "src/core/Router.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockChainlinkAggregator } from "../mocks/MockChainlinkAggregator.sol";
import { IMorphoBase, MarketParams } from "@morpho-blue/interfaces/IMorpho.sol";

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

abstract contract BaseForkTest is Test {
    uint256 constant ONE = 1e18;
    uint256 constant MATURITY = 30 days;

    uint256 constant SENIOR_RATIO = 0.725e18;
    uint256 constant JUNIOR_RATIO = 0.275e18;
    uint256 constant SENIOR_FLOOR = 0.04e18;
    uint256 constant SENIOR_TARGET = 0.06e18;

    uint256 constant INITIAL_PRICE = 1.02e18;

    uint256 constant PRIME_TO_TRANCHE = 7_000_000e18;
    uint256 constant LP_PRIME_AMOUNT = 3_000_000e18;
    uint256 constant LP_SR_AMOUNT = 3_000_000e18;

    uint256 constant MORPHO_LIQUIDITY = 30_000_000e18;
    uint256 constant MORPHO_SR_LIQUIDITY = 30_000_000e18;

    uint24 constant POOL_FEE = 500;

    address constant UNISWAP_V3_POSITION_MANAGER_SEPOLIA = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant UNISWAP_V3_SWAP_ROUTER_SEPOLIA = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant UNISWAP_V3_FACTORY_SEPOLIA = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address constant UNISWAP_V3_QUOTER_V2_SEPOLIA = 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3;
    address constant MORPHO_SEPOLIA = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    ERC20Mock public prime;
    ERC20Mock public usdc;
    MockChainlinkAggregator public oracle;
    TrancheMarket public market;
    Router public router;
    address public uniswapPool;
    address public morpho;

    address public admin;
    address public liquidityProvider;

    function _forkSepolia() internal {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
    }

    function _setupBaseAddresses() internal {
        admin = makeAddr("admin");
        liquidityProvider = makeAddr("liquidityProvider");
    }

    function _deployTokenAndOracle() internal {
        prime = new ERC20Mock("PRIME Token", "PRIME");
        oracle = new MockChainlinkAggregator(8, "PRIME / USD");

        int256 price8Decimals = int256(INITIAL_PRICE / 1e10);
        oracle.setRoundData(price8Decimals, block.timestamp);
    }

    function _deployTrancheMarket() internal {
        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: address(prime),
            poolFee: POOL_FEE,
            matureAt: block.timestamp + MATURITY,
            seniorRatio: SENIOR_RATIO,
            admin: admin,
            priceFeed: address(oracle),
            seniorFloor: SENIOR_FLOOR,
            seniorTarget: SENIOR_TARGET,
            liquidationEnabled: true,
            liquidationBuffer: 0.025e18,
            liquidationReward: 0.025e18
        });

        market = new TrancheMarket(params);
    }

    function _setupLiquidityProvider() internal {
        uint256 totalPrimeForLP = LP_PRIME_AMOUNT + PRIME_TO_TRANCHE;

        prime.mint(liquidityProvider, totalPrimeForLP);

        vm.startPrank(liquidityProvider);
        prime.approve(address(market), PRIME_TO_TRANCHE);
        market.tranche(PRIME_TO_TRANCHE, liquidityProvider);
        vm.stopPrank();
    }

    function _createUniswapPool() internal {
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

        uint160 sqrtPriceX96 = 79_228_162_514_264_337_593_543_950_336;

        uniswapPool = positionManager.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);
    }

    function _addLiquidity() internal {
        IPositionManager positionManager = IPositionManager(UNISWAP_V3_POSITION_MANAGER_SEPOLIA);
        address srToken = market.srToken();

        vm.startPrank(liquidityProvider);
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

        int24 tickLower = -1000; // -887220
        int24 tickUpper = 1000; // 887220

        IPositionManager.MintParams memory params = IPositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: liquidityProvider,
            deadline: block.timestamp + 1 hours
        });

        positionManager.mint(params);
        vm.stopPrank();
    }

    // NOTE: In fork tests we impersonate Morpho owner to enable IRM/LLTV.
    // In production deployment, use pre-enabled IRM/LLTV values from Morpho governance.
    function _setupMorphoMarket() internal {
        morpho = MORPHO_SEPOLIA;
        IMorphoBase morphoContract = IMorphoBase(morpho);
        uint256 lltv = 0.945e18;

        address morphoOwner = morphoContract.owner();
        vm.startPrank(morphoOwner);
        morphoContract.enableIrm(address(0));
        morphoContract.enableLltv(lltv);
        vm.stopPrank();

        usdc = new ERC20Mock("USD Coin", "USDC");

        MarketParams memory primeMarketParams = MarketParams({
            loanToken: address(prime), collateralToken: address(usdc), oracle: address(0), irm: address(0), lltv: lltv
        });
        morphoContract.createMarket(primeMarketParams);

        prime.mint(address(this), MORPHO_LIQUIDITY);
        prime.approve(morpho, MORPHO_LIQUIDITY);
        morphoContract.supply(primeMarketParams, MORPHO_LIQUIDITY, 0, address(this), "");
    }

    function _deployRouter() internal {
        router = new Router(UNISWAP_V3_SWAP_ROUTER_SEPOLIA, morpho, admin);
        vm.prank(admin);
        router.setMarketWhitelisted(address(market), true);
    }

    function _setOraclePrice(uint256 price18Decimals) internal {
        int256 price8Decimals = int256(price18Decimals / 1e10);
        oracle.setRoundData(price8Decimals, block.timestamp);
    }

    function _warpToMaturity() internal {
        vm.warp(block.timestamp + MATURITY + 1);
        _setOraclePrice(INITIAL_PRICE);
    }
}
