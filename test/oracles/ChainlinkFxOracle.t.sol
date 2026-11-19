// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ChainlinkFxOracle, IAggregatorV3} from "../../src/oracles/ChainlinkFxOracle.sol";

/// @dev Stands in for a Chainlink feed so tests can set any answer.
contract MockAggregator is IAggregatorV3 {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Stands in for Chainlink's sequencer uptime feed: 0 is up, 1 is down.
contract MockSequencerFeed is IAggregatorV3 {
    int256 public status;
    uint256 public startedAt;

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function set(int256 status_, uint256 startedAt_) external {
        status = status_;
        startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, status, startedAt, startedAt, 1);
    }
}

contract ChainlinkFxOracleTest is Test {
    IAggregatorV3 internal constant NO_SEQUENCER = IAggregatorV3(address(0));

    MockAggregator internal feed;
    ChainlinkFxOracle internal oracle;

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new MockAggregator(8);
        oracle = new ChainlinkFxOracle(feed, NO_SEQUENCER, "EUR / USD");
    }

    function test_Latest_ScalesEightDecimalsToEighteen() public {
        feed.set(1.08e8, block.timestamp - 60);

        (uint256 price, uint64 updatedAt) = oracle.latest();
        assertEq(price, 1.08e18);
        assertEq(updatedAt, block.timestamp - 60);
    }

    function test_Latest_EighteenDecimalFeed_IsUnchanged() public {
        MockAggregator feed18 = new MockAggregator(18);
        feed18.set(6.8e14, block.timestamp);
        ChainlinkFxOracle oracle18 = new ChainlinkFxOracle(feed18, NO_SEQUENCER, "NGN / USD");

        (uint256 price,) = oracle18.latest();
        assertEq(price, 6.8e14);
    }

    function test_Latest_BrokenFeed_ReportsZero() public {
        feed.set(0, block.timestamp);
        (uint256 price,) = oracle.latest();
        assertEq(price, 0);

        feed.set(-1, block.timestamp);
        (price,) = oracle.latest();
        assertEq(price, 0);
    }

    function testFuzz_Latest_Scales(uint64 answer, uint8 feedDecimals) public {
        feedDecimals = uint8(bound(feedDecimals, 0, 18));
        answer = uint64(bound(answer, 1, type(uint64).max));
        MockAggregator fuzzFeed = new MockAggregator(feedDecimals);
        fuzzFeed.set(int256(uint256(answer)), block.timestamp);
        ChainlinkFxOracle fuzzOracle = new ChainlinkFxOracle(fuzzFeed, NO_SEQUENCER, "fuzz");

        (uint256 price,) = fuzzOracle.latest();
        assertEq(price, uint256(answer) * 10 ** (18 - feedDecimals));
    }

    function test_Description() public view {
        assertEq(oracle.description(), "EUR / USD");
    }

    function test_RevertWhen_FeedIsZeroAddress() public {
        vm.expectRevert(ChainlinkFxOracle.ZeroAddress.selector);
        new ChainlinkFxOracle(IAggregatorV3(address(0)), NO_SEQUENCER, "EUR / USD");
    }

    function test_RevertWhen_FeedDecimalsTooHigh() public {
        MockAggregator feed19 = new MockAggregator(19);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkFxOracle.DecimalsTooHigh.selector, uint8(19)));
        new ChainlinkFxOracle(feed19, NO_SEQUENCER, "EUR / USD");
    }

    // ---------- Sequencer uptime ----------

    function _withSequencer() internal returns (MockSequencerFeed sequencer, ChainlinkFxOracle withCheck) {
        sequencer = new MockSequencerFeed();
        withCheck = new ChainlinkFxOracle(feed, sequencer, "EUR / USD");
        feed.set(1.08e8, block.timestamp - 60);
    }

    function test_Sequencer_Up_ReportsFeedTime() public {
        (MockSequencerFeed sequencer, ChainlinkFxOracle withCheck) = _withSequencer();
        sequencer.set(0, block.timestamp - 2 hours);

        (uint256 price, uint64 updatedAt) = withCheck.latest();
        assertEq(price, 1.08e18);
        assertEq(updatedAt, block.timestamp - 60);
    }

    function test_Sequencer_Down_ReportsNeverUpdated() public {
        (MockSequencerFeed sequencer, ChainlinkFxOracle withCheck) = _withSequencer();
        sequencer.set(1, block.timestamp - 2 hours);

        (, uint64 updatedAt) = withCheck.latest();
        assertEq(updatedAt, 0);
    }

    function test_Sequencer_JustRestarted_ReportsNeverUpdated() public {
        (MockSequencerFeed sequencer, ChainlinkFxOracle withCheck) = _withSequencer();
        sequencer.set(0, block.timestamp - 10 minutes); // back up, but inside the grace period

        (, uint64 updatedAt) = withCheck.latest();
        assertEq(updatedAt, 0);

        vm.warp(block.timestamp + withCheck.SEQUENCER_GRACE_PERIOD());
        (, updatedAt) = withCheck.latest();
        assertGt(updatedAt, 0);
    }

    function test_Sequencer_InvalidRound_ReportsNeverUpdated() public {
        (MockSequencerFeed sequencer, ChainlinkFxOracle withCheck) = _withSequencer();
        sequencer.set(0, 0);

        (, uint64 updatedAt) = withCheck.latest();
        assertEq(updatedAt, 0);
    }
}
