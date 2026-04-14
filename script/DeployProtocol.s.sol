// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AyniOracle} from "../src/AyniOracle.sol";
import {AyniDestinationSettler} from "../src/AyniDestinationSettler.sol";
import {AyniProtocol} from "../src/AyniProtocol.sol";
import {AyniSolverPool} from "../src/AyniSolverPool.sol";
import {AyniVault} from "../src/AyniVault.sol";
import {AyniVaultFactory} from "../src/AyniVaultFactory.sol";
import {AyniVaultRegistry} from "../src/AyniVaultRegistry.sol";
import {WrappedZkLTC} from "../src/WrappedZkLTC.sol";
import {IERC20Metadata} from "../src/interfaces/IERC20Metadata.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {ScriptBase} from "./ScriptBase.sol";

contract DeployProtocol is ScriptBase {
    event CoreDeployed(address implementation, address registry, address factory, address protocol);
    event TestMarketsDeployed(
        address implementation,
        address registry,
        address factory,
        address protocol,
        address oracle,
        address mock_usdc,
        address mock_usdt,
        address usdc_vault,
        address usdt_vault,
        address usdc_solver_pool,
        address usdt_solver_pool
    );
    event FullStackDeployed(
        address implementation,
        address registry,
        address factory,
        address protocol,
        address destination_settler,
        address wrapped_zkltc,
        address oracle,
        address solver_pool,
        address market_vault
    );

    struct CoreDeployment {
        address implementation;
        address registry;
        address factory;
        address protocol;
    }

    struct FullStackDeployment {
        address implementation;
        address registry;
        address factory;
        address protocol;
        address destination_settler;
        address wrapped_zkltc;
        address oracle;
        address solver_pool;
        address market_vault;
    }

    function run(address owner) external returns (CoreDeployment memory deployment) {
        vm.startBroadcast();
        deployment = _deployCore(owner);
        vm.stopBroadcast();

        emit CoreDeployed(deployment.implementation, deployment.registry, deployment.factory, deployment.protocol);
    }

    function runWithMockDebts(address owner, address collateral, address feed, uint256 initial_mock_liquidity)
        external
        returns (
            CoreDeployment memory deployment,
            address oracle,
            address mock_usdc,
            address mock_usdt,
            address usdc_vault,
            address usdt_vault,
            address usdc_solver_pool,
            address usdt_solver_pool
        )
    {
        vm.startBroadcast();

        deployment = _deployCore(owner);

        oracle = address(new AyniOracle(feed, owner));
        mock_usdc = address(new MockUSDC());
        mock_usdt = address(new MockUSDT());

        usdc_vault = AyniProtocol(deployment.protocol).create_market(collateral, mock_usdc, oracle, owner);
        usdt_vault = AyniProtocol(deployment.protocol).create_market(collateral, mock_usdt, oracle, owner);

        usdc_solver_pool = address(
            new AyniSolverPool(mock_usdc, deployment.protocol, owner, "Ayni USDC Solver Share", "SWzkltc", _defaultRateModel())
        );
        usdt_solver_pool = address(
            new AyniSolverPool(mock_usdt, deployment.protocol, owner, "Ayni USDT Solver Share", "SWzkltc", _defaultRateModel())
        );

        AyniProtocol(deployment.protocol).set_solver_pool(collateral, mock_usdc, usdc_solver_pool);
        AyniProtocol(deployment.protocol).set_solver_pool(collateral, mock_usdt, usdt_solver_pool);

        if (initial_mock_liquidity > 0) {
            MockUSDC(mock_usdc).mint(owner, initial_mock_liquidity);
            MockUSDT(mock_usdt).mint(owner, initial_mock_liquidity);

            MockUSDC(mock_usdc).approve(deployment.protocol, initial_mock_liquidity);
            AyniProtocol(deployment.protocol).seed_solver_pool(collateral, mock_usdc, initial_mock_liquidity);

            MockUSDT(mock_usdt).approve(deployment.protocol, initial_mock_liquidity);
            AyniProtocol(deployment.protocol).seed_solver_pool(collateral, mock_usdt, initial_mock_liquidity);
        }

        vm.stopBroadcast();

        emit TestMarketsDeployed(
            deployment.implementation,
            deployment.registry,
            deployment.factory,
            deployment.protocol,
            oracle,
            mock_usdc,
            mock_usdt,
            usdc_vault,
            usdt_vault,
            usdc_solver_pool,
            usdt_solver_pool
        );
    }

    function runFull(address owner, address debt_asset, address feed)
        external
        returns (FullStackDeployment memory deployment)
    {
        require(debt_asset != address(0), "Deploy: bad debt asset");
        require(feed != address(0), "Deploy: bad feed");

        vm.startBroadcast();

        CoreDeployment memory core = _deployCore(owner);
        deployment.implementation = core.implementation;
        deployment.registry = core.registry;
        deployment.factory = core.factory;
        deployment.protocol = core.protocol;

        deployment.destination_settler = address(new AyniDestinationSettler(core.protocol));
        AyniProtocol(core.protocol).set_destination_settler(deployment.destination_settler);

        deployment.wrapped_zkltc = address(new WrappedZkLTC());
        deployment.oracle = address(new AyniOracle(feed, owner));
        deployment.market_vault =
            AyniProtocol(core.protocol).create_market(deployment.wrapped_zkltc, debt_asset, deployment.oracle, owner);

        string memory asset_symbol = IERC20Metadata(debt_asset).symbol();
        deployment.solver_pool = address(
            new AyniSolverPool(
                debt_asset,
                core.protocol,
                owner,
                string(abi.encodePacked("Ayni ", asset_symbol, " Solver Share")),
                "SWzkltc",
                _defaultRateModel()
            )
        );

        AyniProtocol(core.protocol).set_solver_pool(deployment.wrapped_zkltc, debt_asset, deployment.solver_pool);

        vm.stopBroadcast();

        emit FullStackDeployed(
            deployment.implementation,
            deployment.registry,
            deployment.factory,
            deployment.protocol,
            deployment.destination_settler,
            deployment.wrapped_zkltc,
            deployment.oracle,
            deployment.solver_pool,
            deployment.market_vault
        );
    }

    function runFullWithOracle(address owner, address debt_asset, address oracle_)
        external
        returns (FullStackDeployment memory deployment)
    {
        require(debt_asset != address(0), "Deploy: bad debt asset");
        require(oracle_ != address(0), "Deploy: bad oracle");
        require(oracle_.code.length > 0, "Deploy: bad oracle");

        vm.startBroadcast();

        CoreDeployment memory core = _deployCore(owner);
        deployment.implementation = core.implementation;
        deployment.registry = core.registry;
        deployment.factory = core.factory;
        deployment.protocol = core.protocol;

        deployment.destination_settler = address(new AyniDestinationSettler(core.protocol));
        AyniProtocol(core.protocol).set_destination_settler(deployment.destination_settler);

        deployment.wrapped_zkltc = address(new WrappedZkLTC());
        deployment.oracle = oracle_;
        deployment.market_vault =
            AyniProtocol(core.protocol).create_market(deployment.wrapped_zkltc, debt_asset, deployment.oracle, owner);

        string memory asset_symbol = IERC20Metadata(debt_asset).symbol();
        deployment.solver_pool = address(
            new AyniSolverPool(
                debt_asset,
                core.protocol,
                owner,
                string(abi.encodePacked("Ayni ", asset_symbol, " Solver Share")),
                "SWzkltc",
                _defaultRateModel()
            )
        );

        AyniProtocol(core.protocol).set_solver_pool(deployment.wrapped_zkltc, debt_asset, deployment.solver_pool);

        vm.stopBroadcast();

        emit FullStackDeployed(
            deployment.implementation,
            deployment.registry,
            deployment.factory,
            deployment.protocol,
            deployment.destination_settler,
            deployment.wrapped_zkltc,
            deployment.oracle,
            deployment.solver_pool,
            deployment.market_vault
        );
    }

    function _deployCore(address owner) internal returns (CoreDeployment memory deployment) {
        require(owner != address(0), "Deploy: bad owner");

        deployment.implementation = address(new AyniVault());
        deployment.registry = address(new AyniVaultRegistry(owner));
        deployment.factory = address(new AyniVaultFactory(deployment.implementation, deployment.registry, owner));
        deployment.protocol = address(new AyniProtocol(deployment.factory, deployment.registry, owner));

        AyniVaultRegistry(deployment.registry).set_factory(deployment.factory);
        AyniVaultFactory(deployment.factory).set_manager(deployment.protocol);
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
