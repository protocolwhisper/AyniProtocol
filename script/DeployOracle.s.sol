// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AyniOracle} from "../src/AyniOracle.sol";
import {ManualPriceFeed} from "../src/ManualPriceFeed.sol";
import {ScriptBase} from "./ScriptBase.sol";

contract DeployOracle is ScriptBase {
    event OracleDeployed(address oracle, address feed, address owner);
    event OracleWithManualFeedDeployed(address oracle, address feed, address owner, int256 initial_price, uint8 decimals);

    function run(address owner, address feed) external returns (address oracle) {
        require(owner != address(0), "DeployOracle: bad owner");
        require(feed != address(0), "DeployOracle: bad feed");

        vm.startBroadcast();
        oracle = address(new AyniOracle(feed, owner));
        vm.stopBroadcast();

        emit OracleDeployed(oracle, feed, owner);
    }

    function runWithManualFeed(address owner, int256 initial_price, uint8 decimals)
        external
        returns (address feed, address oracle)
    {
        require(owner != address(0), "DeployOracle: bad owner");
        require(initial_price > 0, "DeployOracle: bad price");

        vm.startBroadcast();
        feed = address(new ManualPriceFeed(decimals, initial_price, owner));
        oracle = address(new AyniOracle(feed, owner));
        vm.stopBroadcast();

        emit OracleWithManualFeedDeployed(oracle, feed, owner, initial_price, decimals);
    }
}
