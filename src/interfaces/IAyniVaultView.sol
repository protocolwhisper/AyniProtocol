// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniVaultView {
    function collateral_asset() external view returns (address);

    function debt_asset() external view returns (address);

    function oracle_address() external view returns (address);

    function vault_owner() external view returns (address);

    function protocol_router() external view returns (address);

    function health_factor(address user) external view returns (uint256);

    function collateral_usd(address user) external view returns (uint256);

    function max_borrow(address user) external view returns (uint256);

    function debt_of(address user) external view returns (uint256);

    function paused() external view returns (bool);

    function total_collateral() external view returns (uint256);

    function total_debt() external view returns (uint256);

    function borrow_fee_bps() external view returns (uint256);

    function positions(address user) external view returns (uint256 collateral, uint256 debt, uint256 last_update);

    function active_solver_order(address user) external view returns (bytes32);

    function solver_order(bytes32 order_id)
        external
        view
        returns (
            address borrower,
            uint256 principal,
            uint256 debt_amount,
            uint256 protocol_fee_bps_,
            uint256 expiry,
            uint256 filled_at,
            uint8 status
        );
}
