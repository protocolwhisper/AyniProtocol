// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "./TestBase.sol";
import {WrappedZkLTC} from "../src/WrappedZkLTC.sol";

contract WrappedZkLTCTest is TestBase {
    address internal constant USER = address(0xA11CE);
    address internal constant SPENDER = address(0xBEEF);

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
}
