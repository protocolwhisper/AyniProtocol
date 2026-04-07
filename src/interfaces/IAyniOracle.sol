// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniOracle {
    function get_price() external view returns (uint256);

    function price_decimals() external view returns (uint8);
}
