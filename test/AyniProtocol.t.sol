// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AyniOracle} from "../src/AyniOracle.sol";
import {AyniVault} from "../src/AyniVault.sol";
import {AyniVaultFactory} from "../src/AyniVaultFactory.sol";
import {AyniVaultRegistry} from "../src/AyniVaultRegistry.sol";
import {TestBase} from "./TestBase.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AyniProtocolTest is TestBase {
    uint256 internal constant COLLATERAL_AMOUNT = 10 ether;
    uint256 internal constant BORROW_AMOUNT = 5_000e6;
    address internal constant USER = address(0xA11CE);
    address internal constant VAULT_OWNER = address(0xBEEF);

    MockERC20 internal collateral;
    MockERC20 internal usdc;
    MockAggregatorV3 internal feed;
    AyniOracle internal oracle;
    AyniVault internal implementation;
    AyniVaultRegistry internal registry;
    AyniVaultFactory internal factory;

    function setUp() public {
        collateral = new MockERC20("Collateral", "COL", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        feed = new MockAggregatorV3(8);
        feed.setRoundData(1, 2_000e8, block.timestamp, 1);

        oracle = new AyniOracle(address(feed), address(this));
        implementation = new AyniVault();
        registry = new AyniVaultRegistry(address(this));
        factory = new AyniVaultFactory(address(implementation), address(registry), address(usdc), address(this));

        registry.set_factory(address(factory));
    }

    function test_create_vault_registers_metadata() public {
        address vaultAddress = factory.create_vault(address(collateral), address(oracle), VAULT_OWNER);

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
        assertEq(registry.vault_for_collateral(address(collateral)), vaultAddress);
        assertTrue(registry.is_registered(vaultAddress));
    }

    function test_vault_borrow_sends_usdc_and_accrues_interest() public {
        address vaultAddress = factory.create_vault(address(collateral), address(oracle), VAULT_OWNER);
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
        AyniVaultFactory localFactory = new AyniVaultFactory(
            address(localImplementation), address(localRegistry), address(debtToken), address(this)
        );

        localRegistry.set_factory(address(localFactory));

        address vaultAddress = localFactory.create_vault(address(collateralToken), address(localOracle), VAULT_OWNER);
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
        address vaultAddress = factory.create_vault(address(collateral), address(oracle), VAULT_OWNER);
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
        address vaultAddress = factory.create_vault(address(collateral), address(oracle), VAULT_OWNER);
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
}
