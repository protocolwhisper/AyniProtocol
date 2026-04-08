// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniVaultRegistry {
    function register_vault(
        address vault,
        address collateral_token,
        address debt_asset,
        address oracle,
        address vault_owner
    ) external;
}
