// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
