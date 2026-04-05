#pragma version ~=0.4.3

import AyniVaultCore as vault_core


initializes: vault_core
exports: vault_core.__interface__


@deploy
def __init__(
    collateral_token_: address,
    usdc_: address,
    oracle_: address,
    owner_: address,
):
    vault_core.__init__(collateral_token_, usdc_, oracle_, owner_)
