#pragma version ~=0.4.3

interface AyniVaultRegistry:
    def register_vault(
        vault: address,
        collateral_token: address,
        usdc: address,
        oracle: address,
        vault_owner: address,
    ): nonpayable


owner: immutable(address)
usdc: immutable(address)

vault_blueprint: public(address)
registry: public(address)


event BlueprintUpdated:
    blueprint: address


event RegistryUpdated:
    registry: address


event VaultCreated:
    vault: indexed(address)
    collateral_token: indexed(address)
    usdc: address
    oracle: address
    vault_owner: address


@deploy
def __init__(
    vault_blueprint_: address,
    registry_: address,
    usdc_: address,
    owner_: address,
):
    assert vault_blueprint_ != empty(address), "Factory: bad blueprint"
    assert registry_ != empty(address), "Factory: bad registry"
    assert usdc_ != empty(address), "Factory: bad usdc"
    assert owner_ != empty(address), "Factory: bad owner"

    self.vault_blueprint = vault_blueprint_
    self.registry = registry_

    usdc = usdc_
    owner = owner_


@external
@view
def admin() -> address:
    return owner


@external
@view
def debt_asset() -> address:
    return usdc


@external
def set_vault_blueprint(vault_blueprint_: address):
    assert msg.sender == owner, "Factory: not owner"
    assert vault_blueprint_ != empty(address), "Factory: bad blueprint"

    self.vault_blueprint = vault_blueprint_
    log BlueprintUpdated(vault_blueprint_)


@external
def set_registry(registry_: address):
    assert msg.sender == owner, "Factory: not owner"
    assert registry_ != empty(address), "Factory: bad registry"

    self.registry = registry_
    log RegistryUpdated(registry_)


@external
def create_vault(collateral_token: address, oracle: address, vault_owner: address) -> address:
    assert msg.sender == owner, "Factory: not owner"
    assert self.vault_blueprint != empty(address), "Factory: blueprint not set"
    assert self.registry != empty(address), "Factory: registry not set"
    assert collateral_token != empty(address), "Factory: bad collateral"
    assert oracle != empty(address), "Factory: bad oracle"
    assert vault_owner != empty(address), "Factory: bad vault owner"

    vault: address = create_from_blueprint(
        self.vault_blueprint,
        collateral_token,
        usdc,
        oracle,
        vault_owner,
    )

    extcall AyniVaultRegistry(self.registry).register_vault(
        vault,
        collateral_token,
        usdc,
        oracle,
        vault_owner,
    )

    log VaultCreated(vault, collateral_token, usdc, oracle, vault_owner)
    return vault


@external
def create_vault_with_salt(
    collateral_token: address,
    oracle: address,
    vault_owner: address,
    salt: bytes32,
) -> address:
    assert msg.sender == owner, "Factory: not owner"
    assert self.vault_blueprint != empty(address), "Factory: blueprint not set"
    assert self.registry != empty(address), "Factory: registry not set"
    assert collateral_token != empty(address), "Factory: bad collateral"
    assert oracle != empty(address), "Factory: bad oracle"
    assert vault_owner != empty(address), "Factory: bad vault owner"

    vault: address = create_from_blueprint(
        self.vault_blueprint,
        collateral_token,
        usdc,
        oracle,
        vault_owner,
        salt=salt,
    )

    extcall AyniVaultRegistry(self.registry).register_vault(
        vault,
        collateral_token,
        usdc,
        oracle,
        vault_owner,
    )

    log VaultCreated(vault, collateral_token, usdc, oracle, vault_owner)
    return vault
