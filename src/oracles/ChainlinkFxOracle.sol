// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IFxOracle} from "../interfaces/IFxOracle.sol";

/// @notice The parts of a Chainlink feed we use.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkFxOracle
/// @notice Reads a Chainlink FX feed (base priced in quote) as an 18-decimal price.
/// @dev With a sequencer uptime feed set, reports `updatedAt` 0 while the rollup's
///      sequencer is down or just restarted, which halts the vault.
contract ChainlinkFxOracle is IFxOracle {
    error ZeroAddress();
    error DecimalsTooHigh(uint8 decimals);

    uint8 internal constant ORACLE_DECIMALS = 18;

    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours; // after a restart

    IAggregatorV3 public immutable feed;

    IAggregatorV3 public immutable sequencerFeed; // zero address skips the check

    uint256 private immutable _scale; // feed decimals -> 18
    string private _description;

    constructor(IAggregatorV3 feed_, IAggregatorV3 sequencerFeed_, string memory description_) {
        if (address(feed_) == address(0)) revert ZeroAddress();
        uint8 feedDecimals = feed_.decimals();
        if (feedDecimals > ORACLE_DECIMALS) revert DecimalsTooHigh(feedDecimals);

        feed = feed_;
        sequencerFeed = sequencerFeed_;
        _scale = 10 ** (ORACLE_DECIMALS - feedDecimals);
        _description = description_;
    }

    /// @dev Bad answer -> price 0. Unhealthy sequencer -> `updatedAt` 0. The hook halts on either.
    function latest() external view returns (uint256 price, uint64 updatedAt) {
        (, int256 answer,, uint256 feedUpdatedAt,) = feed.latestRoundData();
        if (answer > 0) price = SafeCast.toUint256(answer) * _scale;
        if (_sequencerHealthy()) updatedAt = SafeCast.toUint64(feedUpdatedAt);
    }

    function description() external view returns (string memory) {
        return _description;
    }

    /// @dev Uptime feed: answer 0 = up, 1 = down. `startedAt` 0 = invalid round.
    function _sequencerHealthy() internal view returns (bool) {
        if (address(sequencerFeed) == address(0)) return true;
        (, int256 status, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        if (status != 0 || startedAt == 0 || startedAt > block.timestamp) return false;
        return block.timestamp - startedAt > SEQUENCER_GRACE_PERIOD;
    }
}
