#pragma version ~=0.4.3

interface AggregatorV3:
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view


owner: immutable(address)

price_feed: public(address)
max_staleness: public(uint256)
fallback_price: public(uint256)
use_fallback: public(bool)


@deploy
def __init__(feed: address, owner_: address):
    assert feed != empty(address), "Oracle: bad feed"
    assert owner_ != empty(address), "Oracle: bad owner"

    self.price_feed = feed
    owner = owner_
    self.max_staleness = 3600
    self.use_fallback = False


@external
@view
def get_price() -> uint256:
    if self.use_fallback:
        assert self.fallback_price > 0, "Oracle: fallback not set"
        return self.fallback_price

    round_id: uint80 = 0
    answer: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint80 = 0
    round_id, answer, started_at, updated_at, answered_in_round = staticcall AggregatorV3(
        self.price_feed
    ).latestRoundData()

    assert updated_at <= block.timestamp, "Oracle: future"
    assert block.timestamp - updated_at <= self.max_staleness, "Oracle: stale"
    assert answered_in_round >= round_id, "Oracle: incomplete"
    assert answer > 0, "Oracle: bad price"
    return convert(answer, uint256)


@external
def set_fallback_price(price: uint256):
    assert msg.sender == owner, "Oracle: not owner"
    assert price > 0, "Oracle: bad price"
    self.fallback_price = price


@external
def set_use_fallback(v: bool):
    assert msg.sender == owner, "Oracle: not owner"
    if v:
        assert self.fallback_price > 0, "Oracle: fallback not set"
    self.use_fallback = v


@external
def set_price_feed(feed: address):
    assert msg.sender == owner, "Oracle: not owner"
    assert feed != empty(address), "Oracle: bad feed"
    self.price_feed = feed


@external
def set_max_staleness(v: uint256):
    assert msg.sender == owner, "Oracle: not owner"
    assert v > 0, "Oracle: bad staleness"
    self.max_staleness = v
