// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

contract ManualPriceFeed is IAggregatorV3 {
    address private immutable _owner;

    uint8 public immutable decimals;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    event PriceUpdated(uint80 roundId, int256 answer, uint256 updatedAt);

    modifier onlyOwner() {
        require(msg.sender == _owner, "ManualPriceFeed: not owner");
        _;
    }

    constructor(uint8 decimals_, int256 initialAnswer_, address owner_) {
        require(owner_ != address(0), "ManualPriceFeed: bad owner");
        require(initialAnswer_ > 0, "ManualPriceFeed: bad answer");

        decimals = decimals_;
        _owner = owner_;
        _setPrice(initialAnswer_);
    }

    function admin() external view returns (address) {
        return _owner;
    }

    function setPrice(int256 newAnswer) external onlyOwner {
        require(newAnswer > 0, "ManualPriceFeed: bad answer");
        _setPrice(newAnswer);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }

    function _setPrice(int256 newAnswer) internal {
        _roundId += 1;
        _answer = newAnswer;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;

        emit PriceUpdated(_roundId, newAnswer, _updatedAt);
    }
}
