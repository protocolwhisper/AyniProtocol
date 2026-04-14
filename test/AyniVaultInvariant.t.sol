// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AyniOracle} from "../src/AyniOracle.sol";
import {AyniProtocol} from "../src/AyniProtocol.sol";
import {AyniLiquidityPool} from "../src/AyniLiquidityPool.sol";
import {AyniVault} from "../src/AyniVault.sol";
import {AyniVaultFactory} from "../src/AyniVaultFactory.sol";
import {AyniVaultRegistry} from "../src/AyniVaultRegistry.sol";
import {TestBase} from "./TestBase.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AyniVaultInvariantTest is TestBase {
    address internal constant VAULT_OWNER = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA20);

    MockERC20 internal collateral;
    MockERC20 internal usdc;
    AyniVault internal vault;
    AyniProtocol internal protocol;
    AyniLiquidityPool internal pool;
    AyniVaultHandler internal handler;

    function setUp() public {
        collateral = new MockERC20("Collateral", "COL", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setRoundData(1, 2_000e8, block.timestamp, 1);

        AyniOracle oracle = new AyniOracle(address(feed), address(this));
        AyniVault implementation = new AyniVault();
        AyniVaultRegistry registry = new AyniVaultRegistry(address(this));
        protocol = new AyniProtocol(
            address(new AyniVaultFactory(address(implementation), address(registry), address(this))),
            address(registry),
            address(this)
        );
        AyniVaultFactory factory = AyniVaultFactory(protocol.factory_address());

        registry.set_factory(address(factory));
        factory.set_manager(address(protocol));

        vault = AyniVault(protocol.create_market(address(collateral), address(usdc), address(oracle), VAULT_OWNER));
        pool = new AyniLiquidityPool(address(usdc), address(protocol), address(this), "Ayni Liquidity Pool", "SWzkltc", _defaultRateModel());
        protocol.set_liquidity_pool(address(collateral), address(usdc), address(pool));

        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(100_000_000e6, address(this));

        handler = new AyniVaultHandler(protocol, vault, collateral, usdc, feed, ALICE, BOB, CAROL);
    }

    function testFuzz_StatefulVaultAccounting(
        uint256[12] memory actorSeeds,
        uint256[12] memory actionSeeds,
        uint256[12] memory amountSeeds,
        uint256[12] memory elapsedSeeds
    ) public {
        for (uint256 i = 0; i < actionSeeds.length; i++) {
            uint256 action = actionSeeds[i] % 5;

            if (action == 0) {
                handler.deposit(actorSeeds[i], amountSeeds[i]);
            } else if (action == 1) {
                handler.withdraw(actorSeeds[i], amountSeeds[i]);
            } else if (action == 2) {
                handler.borrow(actorSeeds[i], amountSeeds[i]);
            } else if (action == 3) {
                handler.repay(actorSeeds[i], amountSeeds[i]);
            } else {
                handler.warp(elapsedSeeds[i]);
            }

            _assertVaultAccounting();
        }
    }

    function _assertVaultAccounting() internal view {
        assertEq(vault.total_collateral(), collateral.balanceOf(address(vault)));
        assertEq(vault.total_debt(), handler.totalTrackedDebt());
    }

    function _defaultRateModel() internal pure returns (AyniLiquidityPool.RateModelConfig memory) {
        return AyniLiquidityPool.RateModelConfig({
            optimalUtilization: 65 * 1e25,
            baseRate: 3 * 1e25,
            slope1: 12 * 1e25,
            slope2: 150 * 1e25,
            reserveFactor: 15 * 1e25
        });
    }
}

contract AyniVaultHandler is TestBase {
    uint256 internal constant MAX_COLLATERAL = 1_000 ether;

    AyniProtocol internal immutable protocol;
    AyniVault internal immutable vault;
    MockERC20 internal immutable collateral;
    MockERC20 internal immutable usdc;
    MockAggregatorV3 internal immutable feed;

    address[3] internal actors;
    uint80 internal roundId;

    constructor(
        AyniProtocol protocol_,
        AyniVault vault_,
        MockERC20 collateral_,
        MockERC20 usdc_,
        MockAggregatorV3 feed_,
        address actor0,
        address actor1,
        address actor2
    ) {
        protocol = protocol_;
        vault = vault_;
        collateral = collateral_;
        usdc = usdc_;
        feed = feed_;
        actors = [actor0, actor1, actor2];
        roundId = 1;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, vault.min_collateral(), MAX_COLLATERAL);

        collateral.mint(actor, amount);

        vm.startPrank(actor);
        collateral.approve(address(vault), type(uint256).max);
        try vault.deposit(amount) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        (uint256 collateralBalance,,) = vault.positions(actor);

        if (collateralBalance == 0) {
            return;
        }

        amount = bound(amount, 1, collateralBalance);

        vm.prank(actor);
        try vault.withdraw(amount) {} catch {}
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 maxDebt = vault.max_borrow(actor);

        if (maxDebt == 0) {
            return;
        }

        amount = bound(amount, 1, maxDebt);

        vm.prank(actor);
        try protocol.borrow(address(collateral), address(usdc), amount) {} catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 debt = vault.debt_of(actor);

        if (debt == 0) {
            return;
        }

        amount = bound(amount, 1, debt);
        usdc.mint(actor, amount);

        vm.startPrank(actor);
        usdc.approve(address(protocol), type(uint256).max);
        try protocol.repay(address(collateral), address(usdc), amount) {} catch {}
        vm.stopPrank();
    }

    function warp(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 30 days));
        roundId += 1;
        feed.setRoundData(roundId, 2_000e8, block.timestamp, roundId);
    }

    function totalTrackedDebt() external view returns (uint256 totalDebt) {
        for (uint256 i = 0; i < actors.length; i++) {
            (, uint256 debt,) = vault.positions(actors[i]);
            totalDebt += debt;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}
