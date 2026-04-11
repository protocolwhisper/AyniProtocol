// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface Vm {
    function deal(address account, uint256 newBalance) external;

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

    function assertEq(bytes32 left, bytes32 right) internal pure {
        require(left == right, "assert eq(bytes32)");
    }

    function assertTrue(bool value) internal pure {
        require(value, "assert true");
    }

    function assertGt(uint256 left, uint256 right) internal pure {
        require(left > right, "assert gt(uint256)");
    }

    function assertGe(uint256 left, uint256 right) internal pure {
        require(left >= right, "assert ge(uint256)");
    }

    function assertLe(uint256 left, uint256 right) internal pure {
        require(left <= right, "assert le(uint256)");
    }

    function bound(uint256 value, uint256 min_value, uint256 max_value) internal pure returns (uint256) {
        require(min_value <= max_value, "bound");

        if (min_value == max_value) {
            return min_value;
        }

        return min_value + value % (max_value - min_value + 1);
    }
}
