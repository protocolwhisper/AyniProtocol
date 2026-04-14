// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IAyniSolverPool {
    function asset() external view returns (address);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from_, address to, uint256 amount) external returns (bool);

    function totalAssets() external view returns (uint256);

    function availableLiquidity() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function previewWithdraw(uint256 assets) external view returns (uint256);

    function previewRedeem(uint256 shares) external view returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function maxWithdraw(address owner) external view returns (uint256);

    function maxRedeem(address owner) external view returns (uint256);

    function cooldown() external;

    function fundClaim(bytes32 orderId, uint256 principal, address borrower) external;

    function settleRepayment(bytes32 orderId, uint256 amount) external;

    function settleLiquidation(bytes32 orderId, uint256 usdcRecovered) external;

    function currentDebt(bytes32 orderId) external view returns (uint256);

    function remainingPrincipal(bytes32 orderId) external view returns (uint256);

    function utilizationRate() external view returns (uint256);

    function liquidityIndex() external view returns (uint256);
}
