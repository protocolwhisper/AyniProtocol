// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _reentrancy_status;

    modifier nonReentrant() {
        require(_reentrancy_status == NOT_ENTERED, "ReentrancyGuard: reentrant");
        _reentrancy_status = ENTERED;
        _;
        _reentrancy_status = NOT_ENTERED;
    }

    function _initializeReentrancyGuard() internal {
        require(_reentrancy_status == 0, "ReentrancyGuard: initialized");
        _reentrancy_status = NOT_ENTERED;
    }

    function _disableReentrancyGuard() internal {
        _reentrancy_status = ENTERED;
    }
}
