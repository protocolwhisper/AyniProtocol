// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract WrappedZkLTC {
    string public constant name = "Wrapped zkLTC";
    string public constant symbol = "WZKLTC";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    receive() external payable {
        deposit();
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function deposit() public payable {
        _deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "WrappedZkLTC: insufficient balance");

        balanceOf[msg.sender] -= amount;
        emit Transfer(msg.sender, address(0), amount);
        emit Withdrawal(msg.sender, amount);

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "WrappedZkLTC: native transfer failed");
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address from_, address to, uint256 amount) public returns (bool) {
        if (from_ != msg.sender) {
            uint256 allowed = allowance[from_][msg.sender];

            if (allowed != type(uint256).max) {
                allowance[from_][msg.sender] = allowed - amount;
                emit Approval(from_, msg.sender, allowance[from_][msg.sender]);
            }
        }

        _transfer(from_, to, amount);
        return true;
    }

    function _deposit(address account, uint256 amount) internal {
        balanceOf[account] += amount;

        emit Deposit(account, amount);
        emit Transfer(address(0), account, amount);
    }

    function _transfer(address from_, address to, uint256 amount) internal {
        require(to != address(0), "WrappedZkLTC: bad to");

        balanceOf[from_] -= amount;
        balanceOf[to] += amount;

        emit Transfer(from_, to, amount);
    }
}
