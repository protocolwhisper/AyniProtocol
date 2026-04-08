// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract AyniVaultRegistry {
    address private immutable _owner;

    address public factory;
    uint256 public vault_count;

    struct VaultMetadata {
        uint256 id;
        address collateral_token;
        address debt_asset;
        address oracle;
        address vault_owner;
        bool active;
    }

    mapping(address => VaultMetadata) private vault_metadata;
    mapping(uint256 => address) public vault_by_id;
    mapping(bytes32 => address) public vault_for_market;
    mapping(address => bool) public is_registered;

    event FactoryUpdated(address factory);
    event VaultRegistered(
        uint256 indexed id,
        address indexed vault,
        address indexed collateral_token,
        address debt_asset,
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

    function register_vault(
        address vault,
        address collateral_token,
        address debt_asset,
        address oracle,
        address vault_owner
    ) external {
        require(factory != address(0), "Registry: factory not set");
        require(msg.sender == factory, "Registry: not factory");
        require(vault != address(0), "Registry: bad vault");
        require(collateral_token != address(0), "Registry: bad collateral");
        require(debt_asset != address(0), "Registry: bad debt asset");
        require(oracle != address(0), "Registry: bad oracle");
        require(vault_owner != address(0), "Registry: bad vault owner");
        require(!is_registered[vault], "Registry: already registered");
        bytes32 market_key = _marketKey(collateral_token, debt_asset);
        require(vault_for_market[market_key] == address(0), "Registry: market exists");

        vault_count += 1;
        uint256 vault_id = vault_count;

        is_registered[vault] = true;
        vault_by_id[vault_id] = vault;
        vault_for_market[market_key] = vault;

        vault_metadata[vault] = VaultMetadata({
            id: vault_id,
            collateral_token: collateral_token,
            debt_asset: debt_asset,
            oracle: oracle,
            vault_owner: vault_owner,
            active: true
        });

        emit VaultRegistered(vault_id, vault, collateral_token, debt_asset, oracle, vault_owner);
    }

    function set_vault_active(address vault, bool active) external {
        require(msg.sender == _owner, "Registry: not owner");
        require(is_registered[vault], "Registry: unknown vault");

        VaultMetadata storage meta = vault_metadata[vault];
        bytes32 market_key = _marketKey(meta.collateral_token, meta.debt_asset);

        if (active) {
            address current_vault = vault_for_market[market_key];
            require(current_vault == address(0) || current_vault == vault, "Registry: market taken");
            vault_for_market[market_key] = vault;
        } else if (vault_for_market[market_key] == vault) {
            vault_for_market[market_key] = address(0);
        }

        meta.active = active;
        emit VaultStatusUpdated(vault, active);
    }

    function get_vault(address collateral_token, address debt_asset) external view returns (address) {
        return vault_for_market[_marketKey(collateral_token, debt_asset)];
    }

    function get_vault_metadata(address vault)
        external
        view
        returns (uint256, address, address, address, address, bool)
    {
        require(is_registered[vault], "Registry: unknown vault");

        VaultMetadata memory meta = vault_metadata[vault];
        return (meta.id, meta.collateral_token, meta.debt_asset, meta.oracle, meta.vault_owner, meta.active);
    }

    function _marketKey(address collateral_token, address debt_asset) internal pure returns (bytes32) {
        return keccak256(abi.encode(collateral_token, debt_asset));
    }
}
