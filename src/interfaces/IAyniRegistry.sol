// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniRegistry {
    function admin() external view returns (address);

    function factory() external view returns (address);

    function vault_count() external view returns (uint256);

    function get_vault(address collateral_token, address debt_asset) external view returns (address);

    function get_vault_metadata(address vault) external view returns (uint256, address, address, address, address, bool);
}
