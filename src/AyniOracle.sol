// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

contract AyniOracle {
    uint256 public constant CONFIG_DELAY = 1 days;

    bytes32 private constant PARAM_PRICE_FEED = keccak256("price_feed");
    bytes32 private constant PARAM_FALLBACK_PRICE = keccak256("fallback_price");
    bytes32 private constant PARAM_USE_FALLBACK = keccak256("use_fallback");
    bytes32 private constant PARAM_MAX_STALENESS = keccak256("max_staleness");

    address private immutable _owner;

    address public price_feed;
    uint8 public price_feed_decimals;
    uint256 public max_staleness;
    uint256 public fallback_price;
    bool public use_fallback;

    struct PendingAddressChange {
        address value;
        uint256 execute_after;
    }

    struct PendingUintChange {
        uint256 value;
        uint256 execute_after;
    }

    struct PendingBoolChange {
        bool value;
        uint256 execute_after;
    }

    PendingAddressChange private _pending_price_feed;
    PendingUintChange private _pending_fallback_price;
    PendingBoolChange private _pending_use_fallback;
    PendingUintChange private _pending_max_staleness;

    event OracleAddressConfigUpdateScheduled(bytes32 indexed parameter, address new_value, uint256 execute_after);
    event OracleAddressConfigUpdated(bytes32 indexed parameter, address old_value, address new_value);
    event OracleUintConfigUpdateScheduled(bytes32 indexed parameter, uint256 new_value, uint256 execute_after);
    event OracleUintConfigUpdated(bytes32 indexed parameter, uint256 old_value, uint256 new_value);
    event OracleBoolConfigUpdateScheduled(bytes32 indexed parameter, bool new_value, uint256 execute_after);
    event OracleBoolConfigUpdated(bytes32 indexed parameter, bool old_value, bool new_value);

    constructor(address feed, address owner_) {
        require(feed != address(0), "Oracle: bad feed");
        require(feed.code.length > 0, "Oracle: bad feed");
        require(owner_ != address(0), "Oracle: bad owner");

        price_feed = feed;
        price_feed_decimals = _readFeedDecimals(feed);
        _owner = owner_;
        max_staleness = 3600;
    }

    function admin() external view returns (address) {
        return _owner;
    }

    function get_price() external view returns (uint256) {
        if (use_fallback) {
            require(fallback_price > 0, "Oracle: fallback not set");
            return fallback_price;
        }

        (uint80 round_id, int256 answer,, uint256 updated_at, uint80 answered_in_round) =
            IAggregatorV3(price_feed).latestRoundData();

        require(updated_at <= block.timestamp, "Oracle: future");
        require(block.timestamp - updated_at <= max_staleness, "Oracle: stale");
        require(answered_in_round >= round_id, "Oracle: incomplete");
        require(answer > 0, "Oracle: bad price");
        return uint256(answer);
    }

    function price_decimals() external view returns (uint8) {
        return price_feed_decimals;
    }

    function set_fallback_price(uint256 price) external {
        require(msg.sender == _owner, "Oracle: not owner");
        require(price > 0, "Oracle: bad price");
        _scheduleUintConfig(PARAM_FALLBACK_PRICE, _pending_fallback_price, price);
    }

    function set_use_fallback(bool v) external {
        require(msg.sender == _owner, "Oracle: not owner");
        _scheduleBoolConfig(PARAM_USE_FALLBACK, _pending_use_fallback, v);
    }

    function set_price_feed(address feed) external {
        require(msg.sender == _owner, "Oracle: not owner");
        require(feed != address(0), "Oracle: bad feed");
        require(feed.code.length > 0, "Oracle: bad feed");
        _scheduleAddressConfig(PARAM_PRICE_FEED, _pending_price_feed, feed);
    }

    function set_max_staleness(uint256 v) external {
        require(msg.sender == _owner, "Oracle: not owner");
        require(v > 0, "Oracle: bad staleness");
        _scheduleUintConfig(PARAM_MAX_STALENESS, _pending_max_staleness, v);
    }

    function apply_fallback_price() external {
        require(msg.sender == _owner, "Oracle: not owner");

        uint256 new_value = _consumeUintConfig(_pending_fallback_price);
        uint256 old_value = fallback_price;

        fallback_price = new_value;
        emit OracleUintConfigUpdated(PARAM_FALLBACK_PRICE, old_value, new_value);
    }

    function apply_use_fallback() external {
        require(msg.sender == _owner, "Oracle: not owner");

        bool new_value = _consumeBoolConfig(_pending_use_fallback);
        if (new_value) {
            require(fallback_price > 0, "Oracle: fallback not set");
        }

        bool old_value = use_fallback;
        use_fallback = new_value;
        emit OracleBoolConfigUpdated(PARAM_USE_FALLBACK, old_value, new_value);
    }

    function apply_price_feed() external {
        require(msg.sender == _owner, "Oracle: not owner");

        address new_value = _consumeAddressConfig(_pending_price_feed);
        uint8 new_decimals = _readFeedDecimals(new_value);
        address old_value = price_feed;

        price_feed = new_value;
        price_feed_decimals = new_decimals;
        emit OracleAddressConfigUpdated(PARAM_PRICE_FEED, old_value, new_value);
    }

    function apply_max_staleness() external {
        require(msg.sender == _owner, "Oracle: not owner");

        uint256 new_value = _consumeUintConfig(_pending_max_staleness);
        uint256 old_value = max_staleness;

        max_staleness = new_value;
        emit OracleUintConfigUpdated(PARAM_MAX_STALENESS, old_value, new_value);
    }

    function _scheduleAddressConfig(bytes32 parameter, PendingAddressChange storage pending_change, address new_value)
        internal
    {
        uint256 execute_after = block.timestamp + CONFIG_DELAY;
        pending_change.value = new_value;
        pending_change.execute_after = execute_after;

        emit OracleAddressConfigUpdateScheduled(parameter, new_value, execute_after);
    }

    function _scheduleUintConfig(bytes32 parameter, PendingUintChange storage pending_change, uint256 new_value)
        internal
    {
        uint256 execute_after = block.timestamp + CONFIG_DELAY;
        pending_change.value = new_value;
        pending_change.execute_after = execute_after;

        emit OracleUintConfigUpdateScheduled(parameter, new_value, execute_after);
    }

    function _scheduleBoolConfig(bytes32 parameter, PendingBoolChange storage pending_change, bool new_value) internal {
        uint256 execute_after = block.timestamp + CONFIG_DELAY;
        pending_change.value = new_value;
        pending_change.execute_after = execute_after;

        emit OracleBoolConfigUpdateScheduled(parameter, new_value, execute_after);
    }

    function _consumeAddressConfig(PendingAddressChange storage pending_change) internal returns (address value) {
        uint256 execute_after = pending_change.execute_after;
        require(execute_after != 0, "Oracle: change not scheduled");
        require(block.timestamp >= execute_after, "Oracle: config timelock");

        value = pending_change.value;
        pending_change.value = address(0);
        pending_change.execute_after = 0;
    }

    function _consumeUintConfig(PendingUintChange storage pending_change) internal returns (uint256 value) {
        uint256 execute_after = pending_change.execute_after;
        require(execute_after != 0, "Oracle: change not scheduled");
        require(block.timestamp >= execute_after, "Oracle: config timelock");

        value = pending_change.value;
        pending_change.value = 0;
        pending_change.execute_after = 0;
    }

    function _consumeBoolConfig(PendingBoolChange storage pending_change) internal returns (bool value) {
        uint256 execute_after = pending_change.execute_after;
        require(execute_after != 0, "Oracle: change not scheduled");
        require(block.timestamp >= execute_after, "Oracle: config timelock");

        value = pending_change.value;
        pending_change.value = false;
        pending_change.execute_after = 0;
    }

    function _readFeedDecimals(address feed) internal view returns (uint8 decimals_) {
        decimals_ = IAggregatorV3(feed).decimals();
        require(decimals_ <= 18, "Oracle: unsupported decimals");
    }
}
