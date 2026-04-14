// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AyniDestinationSettler} from "../src/AyniDestinationSettler.sol";
import {AyniOracle} from "../src/AyniOracle.sol";
import {AyniProtocol} from "../src/AyniProtocol.sol";
import {AyniSolverPool} from "../src/AyniSolverPool.sol";
import {AyniVault} from "../src/AyniVault.sol";
import {AyniVaultFactory} from "../src/AyniVaultFactory.sol";
import {AyniVaultRegistry} from "../src/AyniVaultRegistry.sol";
import {OnchainCrossChainOrder, ResolvedCrossChainOrder} from "../src/intents/ERC7683.sol";
import {TestBase} from "./TestBase.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AyniProtocolFuzzTest is TestBase {
    uint256 internal constant DEFAULT_COLLATERAL = 10 ether;
    address internal constant USER = address(0xA11CE);
    address internal constant SOLVER = address(0xCAFE);
    address internal constant VAULT_OWNER = address(0xBEEF);

    MockERC20 internal collateral;
    MockERC20 internal usdc;
    MockAggregatorV3 internal feed;
    AyniOracle internal oracle;
    AyniProtocol internal protocol;
    AyniDestinationSettler internal destinationSettler;

    function setUp() public {
        collateral = new MockERC20("Collateral", "COL", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        feed = new MockAggregatorV3(8);
        feed.setRoundData(1, 2_000e8, block.timestamp, 1);

        oracle = new AyniOracle(address(feed), address(this));

        AyniVault implementation = new AyniVault();
        AyniVaultRegistry registry = new AyniVaultRegistry(address(this));
        protocol = new AyniProtocol(
            address(new AyniVaultFactory(address(implementation), address(registry), address(this))),
            address(registry),
            address(this)
        );

        AyniVaultFactory factory = AyniVaultFactory(protocol.factory_address());
        destinationSettler = new AyniDestinationSettler(address(protocol));

        registry.set_factory(address(factory));
        factory.set_manager(address(protocol));
        protocol.set_destination_settler(address(destinationSettler));
    }

    function test_RevertWhen_NonOwnerCreatesMarket() public {
        vm.prank(USER);
        vm.expectRevert(bytes("Protocol: not admin"));
        protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
    }

    function test_RevertWhen_NonDestinationSettlerConfirmsFill() public {
        vm.prank(USER);
        vm.expectRevert(bytes("Protocol: not destination settler"));
        protocol.confirm_fill(bytes32(uint256(1)), USER, "");
    }

    function test_RevertWhen_DirectWithdrawWhileSolverBorrowPending() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);

        collateral.mint(USER, DEFAULT_COLLATERAL);

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), address(usdc), DEFAULT_COLLATERAL);
        protocol.open(_borrowOrder(address(collateral), address(usdc), USER, 5_000e6));

        vm.expectRevert(bytes("Vault: pending solver borrow"));
        vault.withdraw(DEFAULT_COLLATERAL);
        vm.stopPrank();
    }

    function testFuzz_VaultBorrowRepayWithdrawRoundTrip(uint256 collateralSeed, uint256 principalSeed, uint256 elapsedSeed)
        public
    {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);
        AyniSolverPool pool = _deployPool(address(usdc));
        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));

        uint256 collateralAmount = bound(collateralSeed, 1 ether, 10_000 ether);
        uint256 maxLiquidity = 50_000_000e6;

        collateral.mint(USER, collateralAmount);
        usdc.mint(address(this), maxLiquidity);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(maxLiquidity, address(this));

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        usdc.approve(address(protocol), type(uint256).max);

        protocol.deposit(address(collateral), address(usdc), collateralAmount);

        uint256 maxPrincipal = _maxPrincipal(vault, USER);
        uint256 principal = bound(principalSeed, 1, maxPrincipal);

        protocol.borrow(address(collateral), address(usdc), principal);

        vm.warp(block.timestamp + bound(elapsedSeed, 0, 365 days));

        uint256 debtBeforeRepay = vault.debt_of(USER);
        usdc.mint(USER, debtBeforeRepay);

        protocol.repay(address(collateral), address(usdc), type(uint256).max);
        vm.stopPrank();

        (uint256 remainingCollateral, uint256 remainingDebt,) = vault.positions(USER);
        assertEq(remainingCollateral, 0);
        assertEq(remainingDebt, 0);
        assertEq(collateral.balanceOf(USER), collateralAmount);
        assertEq(collateral.balanceOf(vaultAddress), 0);
        assertEq(vault.active_solver_order(USER), bytes32(0));
    }

    function testFuzz_ClaimRepaymentSplitsTreasuryAndSolver(
        uint256 collateralSeed,
        uint256 principalSeed,
        uint256 elapsedSeed
    ) public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);

        uint256 collateralAmount = bound(collateralSeed, 1 ether, 10_000 ether);
        uint256 principal = bound(principalSeed, 1, _maxPrincipalForCollateral(vault, collateralAmount));

        collateral.mint(USER, collateralAmount);
        usdc.mint(SOLVER, 100_000_000e6);

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), address(usdc), collateralAmount);

        OnchainCrossChainOrder memory order = _borrowOrder(address(collateral), address(usdc), USER, principal);
        ResolvedCrossChainOrder memory resolved = protocol.resolve(order);
        protocol.open(order);
        vm.stopPrank();

        bytes32 orderId = resolved.orderId;

        vm.startPrank(SOLVER);
        usdc.approve(address(destinationSettler), type(uint256).max);
        destinationSettler.fill(orderId, resolved.fillInstructions[0].originData, "");
        vm.stopPrank();

        vm.warp(block.timestamp + bound(elapsedSeed, 0, 180 days));

        uint256 debtBeforeRepay = vault.debt_of(USER);
        usdc.mint(USER, debtBeforeRepay);

        uint256 treasuryBefore = usdc.balanceOf(address(this));
        uint256 solverBefore = usdc.balanceOf(SOLVER);

        vm.startPrank(USER);
        usdc.approve(address(protocol), type(uint256).max);
        protocol.repay_claim(orderId, type(uint256).max);
        vm.stopPrank();

        uint256 treasuryDelta = usdc.balanceOf(address(this)) - treasuryBefore;
        uint256 solverDelta = usdc.balanceOf(SOLVER) - solverBefore;
        uint256 actualRepaid = treasuryDelta + solverDelta;
        uint256 expectedProtocolFee = actualRepaid * vault.borrow_fee_bps() / 10_000;

        assertEq(protocol.claim_holder(orderId), address(0));
        assertEq(treasuryDelta, expectedProtocolFee);
        assertEq(solverDelta, actualRepaid - expectedProtocolFee);
        assertEq(vault.active_solver_order(USER), bytes32(0));
    }

    function _borrowOrder(address collateralToken, address debtToken, address recipient, uint256 requestedAmount)
        internal
        view
        returns (OnchainCrossChainOrder memory)
    {
        return OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 days),
            orderDataType: protocol.AYNI_ORDER_DATA_TYPE(),
            orderData: abi.encode(
                AyniProtocol.AyniOrderData({
                    collateral_token: collateralToken,
                    debt_asset: debtToken,
                    requested_amount: requestedAmount,
                    recipient: bytes32(uint256(uint160(recipient))),
                    destination_chain_id: block.chainid
                })
            )
        });
    }

    function _maxPrincipal(AyniVault vault, address user) internal view returns (uint256) {
        uint256 maxDebt = vault.max_borrow(user);
        return _maxPrincipalFromDebt(vault, maxDebt);
    }

    function _maxPrincipalForCollateral(AyniVault vault, uint256 collateralAmount) internal view returns (uint256) {
        uint256 collateralValue = collateralAmount * 2_000e8 * 1e6 / 1e18 / 1e8;
        uint256 maxDebt = collateralValue * 7_000 / 10_000;
        return _maxPrincipalFromDebt(vault, maxDebt);
    }

    function _maxPrincipalFromDebt(AyniVault vault, uint256 maxDebt) internal view returns (uint256) {
        uint256 feeBps = vault.borrow_fee_bps();
        uint256 maxPrincipal = maxDebt * 10_000 / (10_000 + feeBps);
        assertGt(maxPrincipal, 0);
        return maxPrincipal;
    }

    function _deployPool(address asset_) internal returns (AyniSolverPool pool) {
        pool = new AyniSolverPool(asset_, address(protocol), address(this), "Ayni Solver Share", "SWzkltc", _defaultRateModel());
    }

    function _defaultRateModel() internal pure returns (AyniSolverPool.RateModelConfig memory) {
        return AyniSolverPool.RateModelConfig({
            optimalUtilization: 65 * 1e25,
            baseRate: 3 * 1e25,
            slope1: 12 * 1e25,
            slope2: 150 * 1e25,
            reserveFactor: 15 * 1e25
        });
    }
}
