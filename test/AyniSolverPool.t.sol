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

contract AyniSolverPoolTest is TestBase {
    uint256 internal constant COLLATERAL_AMOUNT = 10 ether;
    uint256 internal constant BORROW_AMOUNT = 5_000e6;
    uint256 internal constant LP_DEPOSIT = 20_000e6;
    address internal constant USER = address(0xA11CE);
    address internal constant LP = address(0xB0B);
    address internal constant SOLVER = address(0xCAFE);
    address internal constant LIQUIDATOR = address(0xF1A7);
    address internal constant VAULT_OWNER = address(0xBEEF);

    MockERC20 internal collateral;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockAggregatorV3 internal feed;
    AyniOracle internal oracle;
    AyniProtocol internal protocol;
    AyniDestinationSettler internal destinationSettler;
    AyniVault internal implementation;
    AyniVaultRegistry internal registry;
    AyniVaultFactory internal factory;
    AyniSolverPool internal pool;
    AyniSolverPool internal usdtPool;

    function setUp() public {
        collateral = new MockERC20("Collateral", "COL", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        feed = new MockAggregatorV3(8);
        feed.setRoundData(1, 2_000e8, block.timestamp, 1);

        oracle = new AyniOracle(address(feed), address(this));
        implementation = new AyniVault();
        registry = new AyniVaultRegistry(address(this));
        protocol = new AyniProtocol(
            address(new AyniVaultFactory(address(implementation), address(registry), address(this))),
            address(registry),
            address(this)
        );
        factory = AyniVaultFactory(protocol.factory_address());
        destinationSettler = new AyniDestinationSettler(address(protocol));
        pool = _deployPool(address(usdc), "Ayni USDC Solver Share", "SWzkltc");
        usdtPool = _deployPool(address(usdt), "Ayni USDT Solver Share", "asUSDT");

        registry.set_factory(address(factory));
        factory.set_manager(address(protocol));
        protocol.set_destination_settler(address(destinationSettler));
    }

    function test_pool_fill_partial_repay_grows_share_price() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(LP, LP_DEPOSIT);
        usdc.mint(USER, 2_000e6);

        vm.startPrank(LP);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LP_DEPOSIT, LP);
        vm.stopPrank();

        bytes32 orderId = _openClaim(vaultAddress, address(usdc));

        protocol.fill_with_pool(orderId);

        assertEq(protocol.claim_holder(orderId), address(pool));
        assertEq(usdc.balanceOf(USER), BORROW_AMOUNT + 2_000e6);
        assertEq(pool.currentDebt(orderId), BORROW_AMOUNT);
        assertEq(pool.totalAssets(), LP_DEPOSIT);

        vm.warp(block.timestamp + 30 days);

        uint256 debtBefore = pool.currentDebt(orderId);

        vm.startPrank(USER);
        usdc.approve(address(protocol), type(uint256).max);
        protocol.repay_claim(orderId, 1_000e6);
        vm.stopPrank();

        assertTrue(pool.currentDebt(orderId) < debtBefore);
        assertTrue(pool.remainingPrincipal(orderId) < BORROW_AMOUNT);
        assertTrue(pool.reserveBalance() > 0);
        assertTrue(pool.convertToAssets(pool.balanceOf(LP)) > LP_DEPOSIT);
        assertTrue(pool.totalAssets() > LP_DEPOSIT);
    }

    function test_market_repay_routes_pool_debt_to_lppool() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(LP, LP_DEPOSIT);
        usdc.mint(USER, 2_000e6);

        vm.startPrank(LP);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LP_DEPOSIT, LP);
        vm.stopPrank();

        bytes32 orderId = _openClaim(vaultAddress, address(usdc));
        protocol.fill_with_pool(orderId);

        vm.warp(block.timestamp + 30 days);

        uint256 debtBefore = pool.currentDebt(orderId);
        uint256 poolBalanceBefore = usdc.balanceOf(address(pool));

        vm.startPrank(USER);
        usdc.approve(address(protocol), type(uint256).max);
        protocol.repay(address(collateral), address(usdc), 1_000e6);
        vm.stopPrank();

        assertEq(protocol.claim_holder(orderId), address(pool));
        assertTrue(pool.currentDebt(orderId) < debtBefore);
        assertEq(usdc.balanceOf(address(pool)), poolBalanceBefore + 1_000e6);
        assertTrue(pool.reserveBalance() > 0);
        assertTrue(pool.convertToAssets(pool.balanceOf(LP)) > LP_DEPOSIT);
    }

    function test_protocol_seed_solver_pool_mints_lp_to_ayni_owner() public {
        protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));

        usdc.mint(address(this), LP_DEPOSIT);
        usdc.approve(address(protocol), type(uint256).max);

        uint256 shares = protocol.seed_solver_pool(address(collateral), address(usdc), LP_DEPOSIT);

        assertEq(pool.balanceOf(address(this)), shares);
        assertEq(pool.totalAssets(), LP_DEPOSIT);
        assertEq(usdc.balanceOf(address(pool)), LP_DEPOSIT);
    }

    function test_market_borrow_uses_lppool_when_vault_has_no_usdc() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);
        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(LP, LP_DEPOSIT);

        vm.startPrank(LP);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LP_DEPOSIT, LP);
        vm.stopPrank();

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), address(usdc), COLLATERAL_AMOUNT);
        protocol.borrow(address(collateral), address(usdc), BORROW_AMOUNT);
        vm.stopPrank();

        bytes32 orderId = vault.active_solver_order(USER);

        assertTrue(orderId != bytes32(0));
        assertEq(protocol.claim_holder(orderId), address(pool));
        assertEq(usdc.balanceOf(USER), BORROW_AMOUNT);
        assertEq(pool.currentDebt(orderId), BORROW_AMOUNT);
        assertEq(pool.availableLiquidity(), LP_DEPOSIT - BORROW_AMOUNT);
    }

    function test_market_borrow_opens_intent_when_lppool_is_illiquid() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);
        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));

        collateral.mint(USER, COLLATERAL_AMOUNT);

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), address(usdc), COLLATERAL_AMOUNT);
        bytes32 orderId = protocol.borrow(address(collateral), address(usdc), BORROW_AMOUNT);
        vm.stopPrank();

        (,,,,,,,,,, uint8 statusBeforeFill) = protocol.get_debt_position(orderId);
        assertEq(uint256(statusBeforeFill), uint256(AyniProtocol.ClaimStatus.OPEN));
        assertEq(vault.active_solver_order(USER), orderId);
        assertEq(protocol.claim_holder(orderId), address(0));
        assertEq(usdc.balanceOf(USER), 0);

        bytes memory originData =
            abi.encode(AyniProtocol.FillOriginData({recipient: USER, debt_asset: address(usdc), amount: BORROW_AMOUNT}));

        usdc.mint(SOLVER, 10_000e6);
        vm.startPrank(SOLVER);
        usdc.approve(address(destinationSettler), type(uint256).max);
        destinationSettler.fill(orderId, originData, "");
        vm.stopPrank();

        assertEq(protocol.claim_holder(orderId), SOLVER);
        assertEq(usdc.balanceOf(USER), BORROW_AMOUNT);
        assertEq(pool.currentDebt(orderId), 0);

        uint256 debt = vault.debt_of(USER);
        uint256 treasuryBefore = usdc.balanceOf(address(this));
        uint256 solverBefore = usdc.balanceOf(SOLVER);
        usdc.mint(USER, debt);

        vm.startPrank(USER);
        usdc.approve(address(protocol), type(uint256).max);
        protocol.repay(address(collateral), address(usdc), type(uint256).max);
        vm.stopPrank();

        uint256 treasuryDelta = usdc.balanceOf(address(this)) - treasuryBefore;
        uint256 solverDelta = usdc.balanceOf(SOLVER) - solverBefore;

        assertEq(protocol.claim_holder(orderId), address(0));
        assertEq(vault.active_solver_order(USER), bytes32(0));
        assertEq(collateral.balanceOf(USER), COLLATERAL_AMOUNT);
        assertEq(treasuryDelta, debt * vault.borrow_fee_bps() / 10_000);
        assertEq(solverDelta, debt - treasuryDelta);
    }

    function test_full_pool_repay_releases_collateral() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));
        AyniVault vault = AyniVault(vaultAddress);

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(LP, LP_DEPOSIT);
        usdc.mint(USER, 10_000e6);

        vm.startPrank(LP);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LP_DEPOSIT, LP);
        vm.stopPrank();

        bytes32 orderId = _openClaim(vaultAddress, address(usdc));
        protocol.fill_with_pool(orderId);

        vm.warp(block.timestamp + 30 days);

        vm.startPrank(USER);
        usdc.approve(address(protocol), type(uint256).max);
        protocol.repay_claim(orderId, type(uint256).max);
        vm.stopPrank();

        assertEq(protocol.claim_holder(orderId), address(0));
        assertEq(pool.currentDebt(orderId), 0);
        assertEq(vault.active_solver_order(USER), bytes32(0));
        assertEq(collateral.balanceOf(USER), COLLATERAL_AMOUNT);
    }

    function test_pool_claim_liquidation_sends_collateral_to_liquidator() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));
        AyniVault vault = AyniVault(vaultAddress);

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(LP, LP_DEPOSIT);

        vm.startPrank(LP);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(LP_DEPOSIT, LP);
        vm.stopPrank();

        bytes32 orderId = _openClaim(vaultAddress, address(usdc));
        protocol.fill_with_pool(orderId);

        feed.setRoundData(2, 600e8, block.timestamp, 2);

        uint256 debtToCover = pool.currentDebt(orderId);
        usdc.mint(LIQUIDATOR, debtToCover);

        vm.startPrank(LIQUIDATOR);
        usdc.approve(address(protocol), type(uint256).max);
        protocol.liquidate_claim(orderId);
        vm.stopPrank();

        assertEq(protocol.claim_holder(orderId), address(0));
        assertEq(pool.currentDebt(orderId), 0);
        assertEq(collateral.balanceOf(LIQUIDATOR), COLLATERAL_AMOUNT);
        assertEq(vault.active_solver_order(USER), bytes32(0));
    }

    function test_withdraw_requires_cooldown_window() public {
        usdc.mint(LP, LP_DEPOSIT);

        vm.startPrank(LP);
        usdc.approve(address(pool), type(uint256).max);
        uint256 shares = pool.deposit(LP_DEPOSIT, LP);

        vm.expectRevert(bytes("Pool: cooldown not initiated"));
        pool.withdraw(1_000e6, LP, LP);

        pool.cooldown();

        vm.warp(block.timestamp + 6 days);
        vm.expectRevert(bytes("Pool: cooldown not elapsed"));
        pool.redeem(shares / 2, LP, LP);

        vm.warp(block.timestamp + 1 days);
        uint256 assets = pool.redeem(shares / 2, LP, LP);
        vm.stopPrank();

        assertEq(assets, LP_DEPOSIT / 2);
        assertEq(usdc.balanceOf(LP), LP_DEPOSIT / 2);
    }

    function test_pool_rate_model_updates_are_delayed() public {
        assertTrue(keccak256(bytes(pool.name())) == keccak256(bytes("Ayni USDC Solver Share")));
        assertTrue(keccak256(bytes(pool.symbol())) == keccak256(bytes("SWzkltc")));

        pool.set_rate_model(70 * 1e25, 4 * 1e25, 10 * 1e25, 180 * 1e25, 20 * 1e25);

        vm.expectRevert(bytes("Pool: config timelock"));
        pool.apply_rate_model();

        vm.warp(block.timestamp + pool.CONFIG_DELAY());
        pool.apply_rate_model();

        assertEq(pool.optimalUtilization(), 70 * 1e25);
        assertEq(pool.baseRate(), 4 * 1e25);
        assertEq(pool.slope1(), 10 * 1e25);
        assertEq(pool.slope2(), 180 * 1e25);
        assertEq(pool.reserveFactor(), 20 * 1e25);
    }

    function test_protocol_routes_distinct_markets_to_distinct_pools() public {
        address usdcVault = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        address usdtVault = protocol.create_market(address(collateral), address(usdt), address(oracle), VAULT_OWNER);

        protocol.set_solver_pool(address(collateral), address(usdc), address(pool));
        protocol.set_solver_pool(address(collateral), address(usdt), address(usdtPool));

        assertEq(protocol.get_solver_pool(address(collateral), address(usdc)), address(pool));
        assertEq(protocol.get_solver_pool(address(collateral), address(usdt)), address(usdtPool));

        collateral.mint(USER, COLLATERAL_AMOUNT * 2);
        usdc.mint(LP, LP_DEPOSIT);
        usdt.mint(LP, LP_DEPOSIT);

        vm.startPrank(LP);
        usdc.approve(address(pool), type(uint256).max);
        usdt.approve(address(usdtPool), type(uint256).max);
        pool.deposit(LP_DEPOSIT, LP);
        usdtPool.deposit(LP_DEPOSIT, LP);
        vm.stopPrank();

        bytes32 usdcOrder = _openClaim(usdcVault, address(usdc));
        bytes32 usdtOrder = _openClaim(usdtVault, address(usdt));

        protocol.fill_with_pool(usdcOrder);
        protocol.fill_with_pool(usdtOrder);

        assertEq(protocol.claim_holder(usdcOrder), address(pool));
        assertEq(protocol.claim_holder(usdtOrder), address(usdtPool));
        assertEq(usdc.balanceOf(USER), BORROW_AMOUNT);
        assertEq(usdt.balanceOf(USER), BORROW_AMOUNT);
    }

    function _openClaim(address vaultAddress, address debtToken) internal returns (bytes32 orderId) {
        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), debtToken, COLLATERAL_AMOUNT);

        OnchainCrossChainOrder memory order = _borrowOrder(address(collateral), debtToken, USER);
        ResolvedCrossChainOrder memory resolved = protocol.resolve(order);
        protocol.open(order);
        vm.stopPrank();

        return resolved.orderId;
    }

    function _deployPool(address asset_, string memory name_, string memory symbol_)
        internal
        returns (AyniSolverPool deployedPool)
    {
        deployedPool = new AyniSolverPool(
            asset_,
            address(protocol),
            address(this),
            name_,
            symbol_,
            _defaultRateModel()
        );
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

    function _borrowOrder(address collateralToken, address debtToken, address recipient)
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
                    requested_amount: BORROW_AMOUNT,
                    recipient: bytes32(uint256(uint160(recipient))),
                    destination_chain_id: block.chainid
                })
            )
        });
    }
}
