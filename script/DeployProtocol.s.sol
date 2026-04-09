// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AyniOracle} from "../src/AyniOracle.sol";
import {AyniProtocol} from "../src/AyniProtocol.sol";
import {AyniVault} from "../src/AyniVault.sol";
import {AyniVaultFactory} from "../src/AyniVaultFactory.sol";
import {AyniVaultRegistry} from "../src/AyniVaultRegistry.sol";
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
        address usdt_vault
    );

    struct CoreDeployment {
        address implementation;
        address registry;
        address factory;
        address protocol;
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
            address usdt_vault
        )
    {
        vm.startBroadcast();

        deployment = _deployCore(owner);

        oracle = address(new AyniOracle(feed, owner));
        mock_usdc = address(new MockUSDC());
        mock_usdt = address(new MockUSDT());

        usdc_vault = AyniProtocol(deployment.protocol).create_market(collateral, mock_usdc, oracle, owner);
        usdt_vault = AyniProtocol(deployment.protocol).create_market(collateral, mock_usdt, oracle, owner);

        if (initial_mock_liquidity > 0) {
            MockUSDC(mock_usdc).mint(usdc_vault, initial_mock_liquidity);
            MockUSDT(mock_usdt).mint(usdt_vault, initial_mock_liquidity);
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
            usdt_vault
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
}
