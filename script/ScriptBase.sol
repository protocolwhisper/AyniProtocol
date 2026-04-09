// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface Vm {
    function startBroadcast() external;

    function stopBroadcast() external;
}

abstract contract ScriptBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
}
