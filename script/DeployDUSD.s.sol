// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {DusdERC20} from "../src/DusdERC20.sol";
import {DusdEngine} from "../src/DusdEngine.sol";

contract DeployDUSD is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DusdERC20, DusdEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        DusdERC20 dusd = new DusdERC20();
        DusdEngine dusdEngine = new DusdEngine(tokenAddresses, priceFeedAddresses, address(dusd));
        dusd.transferOwnership(address(dusdEngine));
        vm.stopBroadcast();
        return (dusd, dusdEngine, helperConfig);
    }
}
