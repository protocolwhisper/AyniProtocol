// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniClaimOrigin {
    function confirm_fill(bytes32 order_id, address solver, bytes calldata origin_data) external;
}
