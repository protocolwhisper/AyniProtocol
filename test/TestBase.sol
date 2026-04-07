// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface Vm {
    function prank(address sender) external;

    function startPrank(address sender) external;

    function stopPrank() external;

    function expectRevert(bytes calldata revertData) external;

    function warp(uint256 newTimestamp) external;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 left, uint256 right) internal pure {
        require(left == right, "assert eq(uint256)");
    }

    function assertEq(address left, address right) internal pure {
        require(left == right, "assert eq(address)");
    }

    function assertTrue(bool value) internal pure {
        require(value, "assert true");
    }
}
