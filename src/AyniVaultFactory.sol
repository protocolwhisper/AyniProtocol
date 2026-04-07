// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAyniVault} from "./interfaces/IAyniVault.sol";
import {IAyniVaultRegistry} from "./interfaces/IAyniVaultRegistry.sol";
import {Clones} from "./utils/Clones.sol";

contract AyniVaultFactory {
    address private immutable _owner;
    address private immutable _usdc;

    address public vault_blueprint;
    address public registry;

    event BlueprintUpdated(address blueprint);
    event RegistryUpdated(address registry);
    event VaultCreated(
        address indexed vault, address indexed collateral_token, address usdc, address oracle, address vault_owner
    );

    constructor(address vault_blueprint_, address registry_, address usdc_, address owner_) {
        require(vault_blueprint_ != address(0), "Factory: bad blueprint");
        require(vault_blueprint_.code.length > 0, "Factory: bad blueprint");
        require(registry_ != address(0), "Factory: bad registry");
        require(registry_.code.length > 0, "Factory: bad registry");
        require(usdc_ != address(0), "Factory: bad usdc");
        require(owner_ != address(0), "Factory: bad owner");

        vault_blueprint = vault_blueprint_;
        registry = registry_;
        _usdc = usdc_;
        _owner = owner_;
    }

    function admin() external view returns (address) {
        return _owner;
    }

    function debt_asset() external view returns (address) {
        return _usdc;
    }

    function set_vault_blueprint(address vault_blueprint_) external {
        require(msg.sender == _owner, "Factory: not owner");
        require(vault_blueprint_ != address(0), "Factory: bad blueprint");
        require(vault_blueprint_.code.length > 0, "Factory: bad blueprint");

        vault_blueprint = vault_blueprint_;
        emit BlueprintUpdated(vault_blueprint_);
    }

    function set_registry(address registry_) external {
        require(msg.sender == _owner, "Factory: not owner");
        require(registry_ != address(0), "Factory: bad registry");
        require(registry_.code.length > 0, "Factory: bad registry");

        registry = registry_;
        emit RegistryUpdated(registry_);
    }

    function create_vault(address collateral_token, address oracle, address vault_owner)
        external
        returns (address vault)
    {
        require(msg.sender == _owner, "Factory: not owner");
        require(vault_blueprint != address(0), "Factory: blueprint not set");
        require(registry != address(0), "Factory: registry not set");
        require(collateral_token != address(0), "Factory: bad collateral");
        require(oracle != address(0), "Factory: bad oracle");
        require(vault_owner != address(0), "Factory: bad vault owner");

        vault = Clones.clone(vault_blueprint);
        IAyniVault(vault).initialize(collateral_token, _usdc, oracle, vault_owner);

        IAyniVaultRegistry(registry).register_vault(vault, collateral_token, _usdc, oracle, vault_owner);

        emit VaultCreated(vault, collateral_token, _usdc, oracle, vault_owner);
    }

    function create_vault_with_salt(address collateral_token, address oracle, address vault_owner, bytes32 salt)
        external
        returns (address vault)
    {
        require(msg.sender == _owner, "Factory: not owner");
        require(vault_blueprint != address(0), "Factory: blueprint not set");
        require(registry != address(0), "Factory: registry not set");
        require(collateral_token != address(0), "Factory: bad collateral");
        require(oracle != address(0), "Factory: bad oracle");
        require(vault_owner != address(0), "Factory: bad vault owner");

        vault = Clones.cloneDeterministic(vault_blueprint, salt);
        IAyniVault(vault).initialize(collateral_token, _usdc, oracle, vault_owner);

        IAyniVaultRegistry(registry).register_vault(vault, collateral_token, _usdc, oracle, vault_owner);

        emit VaultCreated(vault, collateral_token, _usdc, oracle, vault_owner);
    }
}
