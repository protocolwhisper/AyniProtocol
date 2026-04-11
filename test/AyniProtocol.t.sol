// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AyniOracle} from "../src/AyniOracle.sol";
import {AyniDestinationSettler} from "../src/AyniDestinationSettler.sol";
import {AyniProtocol} from "../src/AyniProtocol.sol";
import {AyniVault} from "../src/AyniVault.sol";
import {AyniVaultFactory} from "../src/AyniVaultFactory.sol";
import {AyniVaultRegistry} from "../src/AyniVaultRegistry.sol";
import {OnchainCrossChainOrder, ResolvedCrossChainOrder} from "../src/intents/ERC7683.sol";
import {TestBase} from "./TestBase.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AyniProtocolTest is TestBase {
    uint256 internal constant COLLATERAL_AMOUNT = 10 ether;
    uint256 internal constant BORROW_AMOUNT = 5_000e6;
    address internal constant USER = address(0xA11CE);
    address internal constant SOLVER = address(0xCAFE);
    address internal constant CLAIM_BUYER = address(0xD00D);
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

        registry.set_factory(address(factory));
        factory.set_manager(address(protocol));
        protocol.set_destination_settler(address(destinationSettler));
    }

    function test_create_vault_registers_metadata() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);

        (
            uint256 id,
            address collateralToken,
            address debtToken,
            address oracleAddress,
            address vaultOwner,
            bool active
        ) = registry.get_vault_metadata(vaultAddress);

        assertEq(id, 1);
        assertEq(collateralToken, address(collateral));
        assertEq(debtToken, address(usdc));
        assertEq(oracleAddress, address(oracle));
        assertEq(vaultOwner, VAULT_OWNER);
        assertTrue(active);
        assertEq(registry.get_vault(address(collateral), address(usdc)), vaultAddress);
        assertTrue(registry.is_registered(vaultAddress));
    }

    function test_same_collateral_supports_multiple_debt_assets() public {
        address usdcVault = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        address usdtVault = protocol.create_market(address(collateral), address(usdt), address(oracle), VAULT_OWNER);

        assertTrue(usdcVault != usdtVault);
        assertEq(registry.get_vault(address(collateral), address(usdc)), usdcVault);
        assertEq(registry.get_vault(address(collateral), address(usdt)), usdtVault);
    }

    function test_vault_borrow_sends_usdc_and_accrues_interest() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(address(vault), 20_000e6);
        usdc.mint(USER, 1_000e6);

        vm.startPrank(USER);
        collateral.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);

        vault.deposit(COLLATERAL_AMOUNT);
        vault.record_borrow(BORROW_AMOUNT);

        (uint256 depositedCollateral, uint256 debtBeforeInterest,) = vault.positions(USER);
        assertEq(depositedCollateral, COLLATERAL_AMOUNT);
        assertEq(debtBeforeInterest, 5_025e6);
        assertEq(usdc.balanceOf(USER), 6_000e6);
        assertEq(vault.available_liquidity(), 15_000e6);

        vm.warp(block.timestamp + 365 days);
        vault.repay(type(uint256).max);
        vault.withdraw(COLLATERAL_AMOUNT);
        vm.stopPrank();

        (uint256 remainingCollateral, uint256 remainingDebt,) = vault.positions(USER);
        assertEq(remainingCollateral, 0);
        assertEq(remainingDebt, 0);
        assertEq(collateral.balanceOf(USER), COLLATERAL_AMOUNT);
    }

    function test_vault_uses_dynamic_decimals() public {
        MockERC20 collateralToken = new MockERC20("Wrapped BTC", "WBTC", 8);
        MockERC20 debtToken = new MockERC20("DAI", "DAI", 18);
        MockAggregatorV3 localFeed = new MockAggregatorV3(8);
        localFeed.setRoundData(1, 35_000e8, block.timestamp, 1);

        AyniOracle localOracle = new AyniOracle(address(localFeed), address(this));
        AyniVault localImplementation = new AyniVault();
        AyniVaultRegistry localRegistry = new AyniVaultRegistry(address(this));
        AyniProtocol localProtocol = new AyniProtocol(
            address(new AyniVaultFactory(address(localImplementation), address(localRegistry), address(this))),
            address(localRegistry),
            address(this)
        );
        AyniVaultFactory localFactory = AyniVaultFactory(localProtocol.factory_address());

        localRegistry.set_factory(address(localFactory));
        localFactory.set_manager(address(localProtocol));

        address vaultAddress = localProtocol.create_market(
            address(collateralToken), address(debtToken), address(localOracle), VAULT_OWNER
        );
        AyniVault vault = AyniVault(vaultAddress);

        collateralToken.mint(USER, 2e8);
        vm.startPrank(USER);
        collateralToken.approve(address(vault), type(uint256).max);
        vault.deposit(2e8);
        vm.stopPrank();

        assertEq(vault.collateral_decimals(), 8);
        assertEq(vault.debt_decimals(), 18);
        assertEq(vault.oracle_decimals(), 8);
        assertEq(vault.collateral_usd(USER), 70_000e18);
        assertEq(vault.max_borrow(USER), 49_000e18);
    }

    function test_vault_risk_updates_are_delayed() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);

        vm.prank(VAULT_OWNER);
        vault.set_max_ltv(6_500);

        vm.prank(VAULT_OWNER);
        vm.expectRevert(bytes("Vault: config timelock"));
        vault.apply_max_ltv();

        vm.warp(block.timestamp + vault.CONFIG_DELAY());
        vm.prank(VAULT_OWNER);
        vault.apply_max_ltv();

        assertEq(vault.max_ltv(), 6_500);
    }

    function test_oracle_updates_are_delayed() public {
        MockAggregatorV3 nextFeed = new MockAggregatorV3(8);
        nextFeed.setRoundData(2, 1_900e8, block.timestamp, 2);

        oracle.set_price_feed(address(nextFeed));

        vm.expectRevert(bytes("Oracle: config timelock"));
        oracle.apply_price_feed();

        vm.warp(block.timestamp + oracle.CONFIG_DELAY());
        oracle.apply_price_feed();

        assertEq(oracle.price_feed(), address(nextFeed));
        assertEq(uint256(oracle.price_decimals()), 8);
    }

    function test_pause_blocks_new_deposits() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);

        collateral.mint(USER, COLLATERAL_AMOUNT);

        vm.prank(VAULT_OWNER);
        vault.pause();

        vm.startPrank(USER);
        collateral.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("Vault: paused"));
        vault.deposit(COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_protocol_routes_market_actions() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(vaultAddress, 20_000e6);
        usdc.mint(USER, 1_000e6);

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        usdc.approve(vaultAddress, type(uint256).max);

        protocol.deposit(address(collateral), address(usdc), COLLATERAL_AMOUNT);
        protocol.borrow(address(collateral), address(usdc), BORROW_AMOUNT);
        protocol.repay(address(collateral), address(usdc), 6_000e6);
        protocol.withdraw(address(collateral), address(usdc), COLLATERAL_AMOUNT);
        vm.stopPrank();

        assertEq(protocol.get_market(address(collateral), address(usdc)), vaultAddress);
        assertEq(protocol.available_liquidity(address(collateral), address(usdc)), 20_025e6);
    }

    function test_7683_fill_creates_internal_claim_and_routes_repayment() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(SOLVER, 10_000e6);
        usdc.mint(USER, 1_000e6);

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), address(usdc), COLLATERAL_AMOUNT);
        ResolvedCrossChainOrder memory resolved = protocol.resolve(_borrowOrder(address(collateral), address(usdc), USER));
        protocol.open(_borrowOrder(address(collateral), address(usdc), USER));
        vm.stopPrank();

        bytes32 orderId = resolved.orderId;

        vm.startPrank(SOLVER);
        usdc.approve(address(destinationSettler), type(uint256).max);
        destinationSettler.fill(orderId, resolved.fillInstructions[0].originData, "");
        vm.stopPrank();

        assertEq(protocol.claim_holder(orderId), SOLVER);
        assertTrue(vault.active_solver_order(USER) == orderId);
        assertEq(usdc.balanceOf(USER), BORROW_AMOUNT + 1_000e6);

        vm.warp(block.timestamp + 30 days);

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

        assertEq(treasuryDelta, expectedProtocolFee);
        assertEq(solverDelta, actualRepaid - expectedProtocolFee);
        assertEq(protocol.claim_holder(orderId), address(0));
    }

    function test_claim_holder_can_transfer_claim() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(SOLVER, 10_000e6);
        usdc.mint(USER, 1_000e6);

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), address(usdc), COLLATERAL_AMOUNT);
        ResolvedCrossChainOrder memory resolved = protocol.resolve(_borrowOrder(address(collateral), address(usdc), USER));
        protocol.open(_borrowOrder(address(collateral), address(usdc), USER));
        vm.stopPrank();

        bytes32 orderId = resolved.orderId;

        vm.startPrank(SOLVER);
        usdc.approve(address(destinationSettler), type(uint256).max);
        destinationSettler.fill(orderId, resolved.fillInstructions[0].originData, "");
        protocol.transfer_claim(orderId, CLAIM_BUYER);
        vm.stopPrank();

        uint256 buyerBefore = usdc.balanceOf(CLAIM_BUYER);

        vm.startPrank(USER);
        usdc.approve(address(protocol), type(uint256).max);
        protocol.repay_claim(orderId, type(uint256).max);
        vm.stopPrank();

        assertEq(protocol.claim_holder(orderId), address(0));
        assertTrue(usdc.balanceOf(CLAIM_BUYER) > buyerBefore);
    }

    function test_fill_reverts_if_origin_data_is_tampered() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(SOLVER, 10_000e6);

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), address(usdc), COLLATERAL_AMOUNT);
        ResolvedCrossChainOrder memory resolved = protocol.resolve(_borrowOrder(address(collateral), address(usdc), USER));
        protocol.open(_borrowOrder(address(collateral), address(usdc), USER));
        vm.stopPrank();

        bytes32 orderId = resolved.orderId;
        bytes memory maliciousOriginData = abi.encode(SOLVER, address(usdc), BORROW_AMOUNT);

        uint256 solverBefore = usdc.balanceOf(SOLVER);
        uint256 userBefore = usdc.balanceOf(USER);

        vm.startPrank(SOLVER);
        usdc.approve(address(destinationSettler), type(uint256).max);
        vm.expectRevert(bytes("Protocol: bad fill data"));
        destinationSettler.fill(orderId, maliciousOriginData, "");
        vm.stopPrank();

        assertEq(protocol.claim_holder(orderId), address(0));
        assertEq(usdc.balanceOf(SOLVER), solverBefore);
        assertEq(usdc.balanceOf(USER), userBefore);
    }

    function test_liquidated_claim_sends_collateral_to_claim_holder() public {
        address vaultAddress = protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER);
        AyniVault vault = AyniVault(vaultAddress);

        collateral.mint(USER, COLLATERAL_AMOUNT);
        usdc.mint(SOLVER, 10_000e6);

        vm.startPrank(USER);
        collateral.approve(vaultAddress, type(uint256).max);
        protocol.deposit(address(collateral), address(usdc), COLLATERAL_AMOUNT);
        ResolvedCrossChainOrder memory resolved = protocol.resolve(_borrowOrder(address(collateral), address(usdc), USER));
        protocol.open(_borrowOrder(address(collateral), address(usdc), USER));
        vm.stopPrank();

        bytes32 orderId = resolved.orderId;

        vm.startPrank(SOLVER);
        usdc.approve(address(destinationSettler), type(uint256).max);
        destinationSettler.fill(orderId, resolved.fillInstructions[0].originData, "");
        vm.stopPrank();

        feed.setRoundData(2, 600e8, block.timestamp, 2);

        uint256 treasuryBefore = collateral.balanceOf(address(this));
        uint256 solverBefore = collateral.balanceOf(SOLVER);

        protocol.liquidate_claim(orderId);

        uint256 expectedProtocolCut = COLLATERAL_AMOUNT * vault.borrow_fee_bps() / 10_000;
        assertEq(collateral.balanceOf(address(this)) - treasuryBefore, expectedProtocolCut);
        assertEq(collateral.balanceOf(SOLVER) - solverBefore, COLLATERAL_AMOUNT - expectedProtocolCut);
        assertEq(protocol.claim_holder(orderId), address(0));
        assertTrue(vault.active_solver_order(USER) == bytes32(0));
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
