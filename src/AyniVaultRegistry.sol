// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract AyniVaultRegistry {
    address private immutable _owner;

    address public factory;
    uint256 public vault_count;

    struct VaultMetadata {
        uint256 id;
        address collateral_token;
        address usdc;
        address oracle;
        address vault_owner;
        bool active;
    }

    mapping(address => VaultMetadata) private vault_metadata;
    mapping(uint256 => address) public vault_by_id;
    mapping(address => address) public vault_for_collateral;
    mapping(address => bool) public is_registered;

    event FactoryUpdated(address factory);
    event VaultRegistered(
        uint256 indexed id,
        address indexed vault,
        address indexed collateral_token,
        address usdc,
        address oracle,
        address vault_owner
    );
    event VaultStatusUpdated(address indexed vault, bool active);

    constructor(address owner_) {
        require(owner_ != address(0), "Registry: bad owner");
        _owner = owner_;
    }

    function admin() external view returns (address) {
        return _owner;
    }

    function set_factory(address factory_) external {
        require(msg.sender == _owner, "Registry: not owner");
        require(factory_ != address(0), "Registry: bad factory");

        factory = factory_;
        emit FactoryUpdated(factory_);
    }

    function register_vault(address vault, address collateral_token, address usdc, address oracle, address vault_owner)
        external
    {
        require(factory != address(0), "Registry: factory not set");
        require(msg.sender == factory, "Registry: not factory");
        require(vault != address(0), "Registry: bad vault");
        require(collateral_token != address(0), "Registry: bad collateral");
        require(usdc != address(0), "Registry: bad usdc");
        require(oracle != address(0), "Registry: bad oracle");
        require(vault_owner != address(0), "Registry: bad vault owner");
        require(!is_registered[vault], "Registry: already registered");
        require(vault_for_collateral[collateral_token] == address(0), "Registry: collateral exists");

        vault_count += 1;
        uint256 vault_id = vault_count;

        is_registered[vault] = true;
        vault_by_id[vault_id] = vault;
        vault_for_collateral[collateral_token] = vault;

        vault_metadata[vault] = VaultMetadata({
            id: vault_id,
            collateral_token: collateral_token,
            usdc: usdc,
            oracle: oracle,
            vault_owner: vault_owner,
            active: true
        });

        emit VaultRegistered(vault_id, vault, collateral_token, usdc, oracle, vault_owner);
    }

    function set_vault_active(address vault, bool active) external {
        require(msg.sender == _owner, "Registry: not owner");
        require(is_registered[vault], "Registry: unknown vault");

        VaultMetadata storage meta = vault_metadata[vault];
        address collateral_token = meta.collateral_token;

        if (active) {
            address current_vault = vault_for_collateral[collateral_token];
            require(current_vault == address(0) || current_vault == vault, "Registry: collateral taken");
            vault_for_collateral[collateral_token] = vault;
        } else if (vault_for_collateral[collateral_token] == vault) {
            vault_for_collateral[collateral_token] = address(0);
        }

        meta.active = active;
        emit VaultStatusUpdated(vault, active);
    }

    function get_vault_metadata(address vault)
        external
        view
        returns (uint256, address, address, address, address, bool)
    {
        require(is_registered[vault], "Registry: unknown vault");

        VaultMetadata memory meta = vault_metadata[vault];
        return (meta.id, meta.collateral_token, meta.usdc, meta.oracle, meta.vault_owner, meta.active);
    }
}
