// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Script, console } from "forge-std/Script.sol";
import { TrancheMarket } from "src/core/TrancheMarket.sol";
import { Router } from "src/core/Router.sol";

contract DeployTrancheMainnet is Script {
    // ============ Mainnet Protocol Addresses ============

    address constant UNISWAP_V3_SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // ============ Default Tranche Parameters ============

    uint256 constant MATURITY = 30 days;

    uint256 constant SENIOR_RATIO = 0.725e18;
    uint256 constant SENIOR_FLOOR = 0.04e18;
    uint256 constant SENIOR_TARGET = 0.06e18;

    uint24 constant POOL_FEE = 500;

    bool constant LIQUIDATION_ENABLED = true;
    uint256 constant LIQUIDATION_BUFFER = 0.025e18;
    uint256 constant LIQUIDATION_REWARD = 0.025e18;

    TrancheMarket public market;
    Router public router;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address ua = vm.envAddress("MAINNET_UA_TOKEN");
        address priceFeed = vm.envAddress("MAINNET_PRICE_FEED");
        address admin = vm.envOr("MAINNET_ADMIN", deployer);

        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);
        console.log("UA Token:", ua);
        console.log("Price Feed:", priceFeed);
        console.log("Admin:", admin);

        vm.startBroadcast(deployerPrivateKey);

        _deployTrancheMarket(ua, priceFeed, admin);
        _deployRouter(admin);

        vm.stopBroadcast();

        _logDeployedAddresses(ua, priceFeed);

        // Next steps:
        // 1. Verify contracts on Etherscan
        // 2. Ensure Morpho has UA liquidity for flash loans 
        //    - available liquidity = supply - borrow
        // 3. Create Uniswap V3 pool (UA/srToken) via position manager
        //    - pick correct tick range
        // 4. Add initial liquidity to the pool
    }

    function _deployTrancheMarket(address ua, address priceFeed, address admin) internal {
        console.log("\n=== Deploying TrancheMarket ===");

        TrancheMarket.MarketParams memory params = TrancheMarket.MarketParams({
            ua: ua,
            poolFee: POOL_FEE,
            matureAt: block.timestamp + MATURITY,
            seniorRatio: SENIOR_RATIO,
            admin: admin,
            priceFeed: priceFeed,
            seniorFloor: SENIOR_FLOOR,
            seniorTarget: SENIOR_TARGET,
            liquidationEnabled: LIQUIDATION_ENABLED,
            liquidationBuffer: LIQUIDATION_BUFFER,
            liquidationReward: LIQUIDATION_REWARD
        });

        market = new TrancheMarket(params);
    }

    function _deployRouter(address admin) internal {
        console.log("\n=== Deploying Router ===");

        router = new Router(UNISWAP_V3_SWAP_ROUTER, MORPHO, admin);
        router.setMarketWhitelisted(address(market), true);

        console.log("Router deployed at:", address(router));
        console.log("Market whitelisted:", address(market));
    }

    function _logDeployedAddresses(address ua, address priceFeed) internal view {
        console.log("\n");
        console.log("========================================");
        console.log("       DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Network: Ethereum Mainnet");
        console.log("----------------------------------------");
        console.log("UA Token:           ", ua);
        console.log("Price Feed:         ", priceFeed);
        console.log("TrancheMarket:      ", address(market));
        console.log("Senior Token:       ", market.srToken());
        console.log("Junior Token:       ", market.jrToken());
        console.log("Router:             ", address(router));
        console.log("----------------------------------------");
        console.log("Maturity:           ", market.matureAt());
        console.log("Current timestamp:  ", block.timestamp);
        console.log("Time to maturity:   ", (market.matureAt() - block.timestamp) / 1 days, "days");
        console.log("Senior Ratio:       ", SENIOR_RATIO);
        console.log("Pool Fee:           ", POOL_FEE);
        console.log("========================================");

    }
}
