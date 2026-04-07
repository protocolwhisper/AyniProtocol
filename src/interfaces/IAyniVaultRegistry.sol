// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniVaultRegistry {
    function register_vault(address vault, address collateral_token, address usdc, address oracle, address vault_owner)
        external;
}
