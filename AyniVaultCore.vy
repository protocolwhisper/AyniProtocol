#pragma version ~=0.4.3

interface IERC20:
    def approve(spender: address, amount: uint256) -> bool: nonpayable
    def transfer(to: address, amount: uint256) -> bool: nonpayable
    def transferFrom(from_: address, to: address, amount: uint256) -> bool: nonpayable
    def balanceOf(owner: address) -> uint256: view
    def allowance(owner: address, spender: address) -> uint256: view


interface AyniOracle:
    def get_price() -> uint256: view


BPS_DENOMINATOR: constant(uint256) = 10_000
SECONDS_PER_YEAR: constant(uint256) = 31_536_000
USD_CONVERSION_SCALE: constant(uint256) = 10**20
MIN_HEALTH_FACTOR: constant(uint256) = 10**18


event Deposit:
    user: indexed(address)
    amount: uint256


event Withdraw:
    user: indexed(address)
    amount: uint256


event BorrowRecorded:
    user: indexed(address)
    amount: uint256
    fee: uint256


event Repay:
    user: indexed(address)
    amount: uint256


event Liquidated:
    user: indexed(address)
    liquidator: indexed(address)
    collateral_seized: uint256
    debt_covered: uint256


event Paused:
    by: address


event Unpaused:
    by: address


struct Position:
    collateral: uint256
    debt: uint256
    last_update: uint256


collateral_token: immutable(address)
usdc: immutable(address)
oracle: immutable(address)
owner: immutable(address)

max_ltv: public(uint256)
liq_threshold: public(uint256)
liq_penalty: public(uint256)
borrow_fee_bps: public(uint256)
annual_interest_bps: public(uint256)
min_collateral: public(uint256)

paused: public(bool)
total_collateral: public(uint256)
total_debt: public(uint256)

positions: public(HashMap[address, Position])


@deploy
def __init__(
    collateral_token_: address,
    usdc_: address,
    oracle_: address,
    owner_: address,
):
    assert collateral_token_ != empty(address), "Vault: bad collateral"
    assert usdc_ != empty(address), "Vault: bad usdc"
    assert oracle_ != empty(address), "Vault: bad oracle"
    assert owner_ != empty(address), "Vault: bad owner"

    collateral_token = collateral_token_
    usdc = usdc_
    oracle = oracle_
    owner = owner_

    self.max_ltv = 7000
    self.liq_threshold = 8000
    self.liq_penalty = 1000
    self.borrow_fee_bps = 50
    self.annual_interest_bps = 500
    self.min_collateral = 10**16


@external
@nonreentrant
def deposit(amount: uint256):
    assert not self.paused, "Vault: paused"
    assert amount >= self.min_collateral, "below minimum"

    self._accrue(msg.sender)

    self.positions[msg.sender].collateral += amount
    self.total_collateral += amount

    assert extcall IERC20(collateral_token).transferFrom(msg.sender, self, amount), "deposit transfer failed"

    log Deposit(msg.sender, amount)


@external
@nonreentrant
def withdraw(amount: uint256):
    assert amount > 0, "amount=0"

    self._accrue(msg.sender)

    new_collateral: uint256 = self.positions[msg.sender].collateral - amount
    assert self._health_factor_after(
        new_collateral,
        self.positions[msg.sender].debt,
    ) >= MIN_HEALTH_FACTOR, "would undercollateralize"

    self.positions[msg.sender].collateral = new_collateral
    self.total_collateral -= amount

    assert extcall IERC20(collateral_token).transfer(msg.sender, amount), "withdraw transfer failed"

    log Withdraw(msg.sender, amount)


@external
@nonreentrant
def record_borrow(amount: uint256):
    assert not self.paused, "Vault: paused"
    assert amount > 0, "amount=0"

    self._accrue(msg.sender)

    fee: uint256 = amount * self.borrow_fee_bps // BPS_DENOMINATOR
    new_debt: uint256 = self.positions[msg.sender].debt + amount + fee
    col_usd: uint256 = self._collateral_usd(msg.sender)

    assert col_usd > 0, "no collateral"
    assert new_debt * BPS_DENOMINATOR <= col_usd * self.max_ltv, "exceeds max LTV"

    self.positions[msg.sender].debt = new_debt
    self.total_debt += amount + fee

    log BorrowRecorded(msg.sender, amount, fee)


@external
@nonreentrant
def repay(amount: uint256):
    assert amount > 0, "amount=0"

    self._accrue(msg.sender)

    actual: uint256 = min(amount, self.positions[msg.sender].debt)
    assert actual > 0, "no debt"

    self.positions[msg.sender].debt -= actual
    self.total_debt -= actual

    assert extcall IERC20(usdc).transferFrom(msg.sender, self, actual), "repay transfer failed"

    log Repay(msg.sender, actual)


@external
@nonreentrant
def liquidate(user: address, debt_to_cover: uint256):
    assert user != msg.sender, "self liquidation"

    self._accrue(user)

    assert self._health_factor(user) < MIN_HEALTH_FACTOR, "position healthy"
    assert debt_to_cover > 0, "amount=0"
    assert debt_to_cover <= self.positions[user].debt, "too much"

    price: uint256 = staticcall AyniOracle(oracle).get_price()
    collateral_seized: uint256 = (
        debt_to_cover
        * USD_CONVERSION_SCALE
        * (BPS_DENOMINATOR + self.liq_penalty)
        // price
        // BPS_DENOMINATOR
    )
    collateral_seized = min(collateral_seized, self.positions[user].collateral)

    self.positions[user].debt -= debt_to_cover
    self.positions[user].collateral -= collateral_seized
    self.total_debt -= debt_to_cover
    self.total_collateral -= collateral_seized

    assert extcall IERC20(usdc).transferFrom(msg.sender, self, debt_to_cover), "liquidation transfer failed"
    assert extcall IERC20(collateral_token).transfer(msg.sender, collateral_seized), "collateral transfer failed"

    log Liquidated(user, msg.sender, collateral_seized, debt_to_cover)


def _accrue(user: address):
    elapsed: uint256 = block.timestamp - self.positions[user].last_update
    if elapsed == 0 or self.positions[user].debt == 0:
        self.positions[user].last_update = block.timestamp
        return

    interest: uint256 = (
        self.positions[user].debt
        * self.annual_interest_bps
        * elapsed
        // SECONDS_PER_YEAR
        // BPS_DENOMINATOR
    )

    self.positions[user].debt += interest
    self.total_debt += interest
    self.positions[user].last_update = block.timestamp


@view
def _collateral_usd(user: address) -> uint256:
    price: uint256 = staticcall AyniOracle(oracle).get_price()
    return self.positions[user].collateral * price // USD_CONVERSION_SCALE


@view
def _health_factor(user: address) -> uint256:
    if self.positions[user].debt == 0:
        return max_value(uint256)

    col_usd: uint256 = self._collateral_usd(user)
    return (
        col_usd
        * self.liq_threshold
        * MIN_HEALTH_FACTOR
        // self.positions[user].debt
        // BPS_DENOMINATOR
    )


@view
def _health_factor_after(new_col: uint256, new_debt: uint256) -> uint256:
    if new_debt == 0:
        return max_value(uint256)

    price: uint256 = staticcall AyniOracle(oracle).get_price()
    col_usd: uint256 = new_col * price // USD_CONVERSION_SCALE
    return col_usd * self.liq_threshold * MIN_HEALTH_FACTOR // new_debt // BPS_DENOMINATOR


@external
@view
def collateral_asset() -> address:
    return collateral_token


@external
@view
def debt_asset() -> address:
    return usdc


@external
@view
def oracle_address() -> address:
    return oracle


@external
@view
def vault_owner() -> address:
    return owner


@external
@view
def health_factor(user: address) -> uint256:
    return self._health_factor(user)


@external
@view
def collateral_usd(user: address) -> uint256:
    return self._collateral_usd(user)


@external
@view
def max_borrow(user: address) -> uint256:
    col_usd: uint256 = self._collateral_usd(user)
    max_debt: uint256 = col_usd * self.max_ltv // BPS_DENOMINATOR
    if max_debt <= self.positions[user].debt:
        return 0

    return max_debt - self.positions[user].debt


@external
def set_max_ltv(v: uint256):
    assert msg.sender == owner, "Vault: not owner"
    assert v < self.liq_threshold, "LTV must be < liquidation threshold"
    self.max_ltv = v


@external
def set_liq_threshold(v: uint256):
    assert msg.sender == owner, "Vault: not owner"
    assert v > self.max_ltv, "threshold must exceed LTV"
    self.liq_threshold = v


@external
def set_liq_penalty(v: uint256):
    assert msg.sender == owner, "Vault: not owner"
    assert v <= 2000, "max 20%"
    self.liq_penalty = v


@external
def set_borrow_fee(v: uint256):
    assert msg.sender == owner, "Vault: not owner"
    assert v <= 500, "max 5%"
    self.borrow_fee_bps = v


@external
def set_annual_interest_bps(v: uint256):
    assert msg.sender == owner, "Vault: not owner"
    assert v <= 5000, "max 50%"
    self.annual_interest_bps = v


@external
def set_min_collateral(v: uint256):
    assert msg.sender == owner, "Vault: not owner"
    assert v > 0, "min=0"
    self.min_collateral = v


@external
def pause():
    assert msg.sender == owner, "Vault: not owner"
    assert not self.paused, "Vault: paused"
    self.paused = True
    log Paused(msg.sender)


@external
def unpause():
    assert msg.sender == owner, "Vault: not owner"
    assert self.paused, "Vault: not paused"
    self.paused = False
    log Unpaused(msg.sender)


@external
def recover_usdc(to: address, amount: uint256):
    assert msg.sender == owner, "Vault: not owner"
    assert to != empty(address), "Vault: bad to"
    assert extcall IERC20(usdc).transfer(to, amount), "recover transfer failed"
