// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniVault {
    function initialize(address collateral_token_, address usdc_, address oracle_, address owner_) external;
}
