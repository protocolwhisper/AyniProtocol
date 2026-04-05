#pragma version ~=0.4.3


owner: immutable(address)

factory: public(address)
vault_count: public(uint256)


struct VaultMetadata:
    id: uint256
    collateral_token: address
    usdc: address
    oracle: address
    vault_owner: address
    active: bool


vault_metadata: HashMap[address, VaultMetadata]
vault_by_id: public(HashMap[uint256, address])
vault_for_collateral: public(HashMap[address, address])
is_registered: public(HashMap[address, bool])


event FactoryUpdated:
    factory: address


event VaultRegistered:
    id: indexed(uint256)
    vault: indexed(address)
    collateral_token: indexed(address)
    usdc: address
    oracle: address
    vault_owner: address


event VaultStatusUpdated:
    vault: indexed(address)
    active: bool


@deploy
def __init__(owner_: address):
    assert owner_ != empty(address), "Registry: bad owner"
    owner = owner_


@external
@view
def admin() -> address:
    return owner


@external
def set_factory(factory_: address):
    assert msg.sender == owner, "Registry: not owner"
    assert factory_ != empty(address), "Registry: bad factory"

    self.factory = factory_
    log FactoryUpdated(factory_)


@external
def register_vault(
    vault: address,
    collateral_token: address,
    usdc: address,
    oracle: address,
    vault_owner: address,
):
    assert self.factory != empty(address), "Registry: factory not set"
    assert msg.sender == self.factory, "Registry: not factory"
    assert vault != empty(address), "Registry: bad vault"
    assert collateral_token != empty(address), "Registry: bad collateral"
    assert usdc != empty(address), "Registry: bad usdc"
    assert oracle != empty(address), "Registry: bad oracle"
    assert vault_owner != empty(address), "Registry: bad vault owner"
    assert not self.is_registered[vault], "Registry: already registered"
    assert self.vault_for_collateral[collateral_token] == empty(address), "Registry: collateral exists"

    self.vault_count += 1
    vault_id: uint256 = self.vault_count

    self.is_registered[vault] = True
    self.vault_by_id[vault_id] = vault
    self.vault_for_collateral[collateral_token] = vault

    self.vault_metadata[vault].id = vault_id
    self.vault_metadata[vault].collateral_token = collateral_token
    self.vault_metadata[vault].usdc = usdc
    self.vault_metadata[vault].oracle = oracle
    self.vault_metadata[vault].vault_owner = vault_owner
    self.vault_metadata[vault].active = True

    log VaultRegistered(vault_id, vault, collateral_token, usdc, oracle, vault_owner)


@external
def set_vault_active(vault: address, active: bool):
    assert msg.sender == owner, "Registry: not owner"
    assert self.is_registered[vault], "Registry: unknown vault"

    collateral_token: address = self.vault_metadata[vault].collateral_token

    if active:
        current_vault: address = self.vault_for_collateral[collateral_token]
        assert current_vault == empty(address) or current_vault == vault, "Registry: collateral taken"
        self.vault_for_collateral[collateral_token] = vault
    else:
        if self.vault_for_collateral[collateral_token] == vault:
            self.vault_for_collateral[collateral_token] = empty(address)

    self.vault_metadata[vault].active = active
    log VaultStatusUpdated(vault, active)


@external
@view
def get_vault_metadata(vault: address) -> (uint256, address, address, address, address, bool):
    assert self.is_registered[vault], "Registry: unknown vault"

    meta: VaultMetadata = self.vault_metadata[vault]
    return meta.id, meta.collateral_token, meta.usdc, meta.oracle, meta.vault_owner, meta.active
