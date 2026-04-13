// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "./TestBase.sol";
import {WrappedZkLTC} from "../src/WrappedZkLTC.sol";

contract WrappedZkLTCTest is TestBase {
    address internal constant USER = address(0xA11CE);
    address internal constant SPENDER = address(0xBEEF);
    address internal constant RECEIVER = address(0xCAFE);

    WrappedZkLTC internal wrapped;

    function setUp() public {
        wrapped = new WrappedZkLTC();
        vm.deal(USER, 10 ether);
    }

    function test_deposit_mints_wrapped_balance() public {
        vm.prank(USER);
        wrapped.deposit{value: 2 ether}();

        assertEq(wrapped.balanceOf(USER), 2 ether);
        assertEq(address(wrapped).balance, 2 ether);
    }

    function test_receive_mints_wrapped_balance() public {
        vm.prank(USER);
        (bool success,) = address(wrapped).call{value: 1 ether}("");

        assertTrue(success);
        assertEq(wrapped.balanceOf(USER), 1 ether);
        assertEq(address(wrapped).balance, 1 ether);
    }

    function test_withdraw_burns_wrapped_balance() public {
        vm.startPrank(USER);
        wrapped.deposit{value: 3 ether}();
        wrapped.withdraw(1 ether);
        vm.stopPrank();

        assertEq(wrapped.balanceOf(USER), 2 ether);
        assertEq(address(wrapped).balance, 2 ether);
    }

    function test_transfer_from_moves_wrapped_balance() public {
        vm.startPrank(USER);
        wrapped.deposit{value: 1 ether}();
        wrapped.approve(SPENDER, 0.5 ether);
        vm.stopPrank();

        vm.prank(SPENDER);
        wrapped.transferFrom(USER, SPENDER, 0.5 ether);

        assertEq(wrapped.balanceOf(USER), 0.5 ether);
        assertEq(wrapped.balanceOf(SPENDER), 0.5 ether);
    }

    function test_transfer_from_self_does_not_need_allowance() public {
        vm.startPrank(USER);
        wrapped.deposit{value: 1 ether}();
        wrapped.transferFrom(USER, RECEIVER, 0.25 ether);
        vm.stopPrank();

        assertEq(wrapped.balanceOf(USER), 0.75 ether);
        assertEq(wrapped.balanceOf(RECEIVER), 0.25 ether);
    }

    function test_infinite_allowance_is_not_decremented() public {
        vm.startPrank(USER);
        wrapped.deposit{value: 1 ether}();
        wrapped.approve(SPENDER, type(uint256).max);
        vm.stopPrank();

        vm.prank(SPENDER);
        wrapped.transferFrom(USER, RECEIVER, 0.4 ether);

        assertEq(wrapped.allowance(USER, SPENDER), type(uint256).max);
        assertEq(wrapped.balanceOf(RECEIVER), 0.4 ether);
    }

    function test_zero_value_deposit_is_allowed() public {
        vm.prank(USER);
        wrapped.deposit{value: 0}();

        assertEq(wrapped.balanceOf(USER), 0);
        assertEq(address(wrapped).balance, 0);
    }
}
