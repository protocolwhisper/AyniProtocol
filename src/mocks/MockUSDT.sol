// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract MockUSDT {
    string public constant name = "Mock Tether USD";
    string public constant symbol = "mUSDT";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from_, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];

        if (allowed != type(uint256).max) {
            allowance[from_][msg.sender] = allowed - amount;
        }

        balanceOf[from_] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
