// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniClaimDebtRouter {
    function claim_debt_state(bytes32 order_id) external view returns (uint256 current_debt, bool managed_by_pool);
}
