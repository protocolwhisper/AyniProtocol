// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniVaultActions {
    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function record_borrow(uint256 amount) external;

    function repay(uint256 amount) external;

    function liquidate(address user, uint256 debt_to_cover) external;

    function deposit_for(address user, uint256 amount) external;

    function withdraw_for(address user, uint256 amount) external;

    function borrow_for(address user, uint256 amount) external;

    function repay_for(address user, uint256 amount) external;

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

    function repay_claim_for(bytes32 order_id, address user, uint256 amount) external returns (uint256 actual);

    function liquidate_claim_for(bytes32 order_id, address claim_holder_, address treasury_)
        external
        returns (uint256 claim_proceeds, uint256 protocol_proceeds);
}
