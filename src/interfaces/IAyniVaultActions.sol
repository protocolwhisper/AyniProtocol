// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniVaultActions {
    function deposit_for(address user, uint256 amount) external;

    function withdraw_for(address user, uint256 amount) external;

    function open_solver_borrow_for(
        bytes32 order_id,
        address user,
        uint256 principal,
        uint256 debt_amount,
        uint256 expiry,
        uint256 protocol_fee_bps_
    ) external;

    function cancel_solver_borrow_for(bytes32 order_id, address user) external;

    function mark_solver_borrow_filled(bytes32 order_id) external;

    function mark_solver_borrow_filled_with_debt(bytes32 order_id, uint256 debt_amount) external;

    function increase_solver_borrow_for(bytes32 order_id, address user, uint256 debt_increase) external;

    function repay_claim_for(bytes32 order_id, address user, uint256 amount)
        external
        returns (uint256 actual, uint256 remaining_debt);

    function liquidate_claim_for(bytes32 order_id, address claim_holder_, address treasury_)
        external
        returns (uint256 claim_proceeds, uint256 protocol_proceeds);

    function liquidate_pool_claim_for(bytes32 order_id, address recipient)
        external
        returns (uint256 collateral_amount, uint256 debt_covered);
}
