// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniFactory {
    function admin() external view returns (address);

    function vault_blueprint() external view returns (address);

    function registry() external view returns (address);

    function create_vault(address collateral_token, address debt_asset, address oracle, address vault_owner)
        external
        returns (address vault);
}
