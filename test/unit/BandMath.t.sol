// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BandMath} from "../../src/libraries/BandMath.sol";
import {FxMath} from "../../src/libraries/FxMath.sol";
import {Pair} from "../../src/types/FlickTypes.sol";

/// @dev Exposes the library through external calls so reverts can be tested.
contract BandMathHarness {
    function bandPrices(uint256 price, uint16 halfWidthBps) external pure returns (uint256, uint256) {
        return BandMath.bandPrices(price, halfWidthBps);
    }

    function bandTicks(uint256 price, uint16 halfWidthBps, int24 tickSpacing, Pair memory pair)
        external
        pure
        returns (int24, int24)
    {
        return BandMath.bandTicks(price, halfWidthBps, tickSpacing, pair);
    }

    function deviationBps(uint256 price, uint256 ref) external pure returns (uint256) {
        return BandMath.deviationBps(price, ref);
    }

    function needsRecenter(uint256 price, uint256 centre, uint16 thresholdBps) external pure returns (bool) {
        return BandMath.needsRecenter(price, centre, thresholdBps);
    }

    function floorToSpacing(int24 tick, int24 tickSpacing) external pure returns (int24) {
        return BandMath.floorToSpacing(tick, tickSpacing);
    }

    function ceilToSpacing(int24 tick, int24 tickSpacing) external pure returns (int24) {
        return BandMath.ceilToSpacing(tick, tickSpacing);
    }
}

contract BandMathTest is Test {
    BandMathHarness internal band;

    uint256 internal constant EUR_USD = 1.08e18;

    function setUp() public {
        band = new BandMathHarness();
    }

    function _pair(bool baseIsToken0) internal pure returns (Pair memory) {
        return Pair({baseDecimals: 6, quoteDecimals: 6, baseIsToken0: baseIsToken0});
    }

    // ---------- bandPrices ----------

    function test_BandPrices_HalfPercentEachSide() public view {
        (uint256 lower, uint256 upper) = band.bandPrices(EUR_USD, 50);
        assertEq(lower, 1.0746e18);
        assertEq(upper, 1.0854e18);
    }

    function test_RevertWhen_HalfWidthZero() public {
        vm.expectRevert(abi.encodeWithSelector(BandMath.InvalidHalfWidth.selector, uint16(0)));
        band.bandPrices(EUR_USD, 0);
    }

    function test_RevertWhen_HalfWidthIsWholePrice() public {
        vm.expectRevert(abi.encodeWithSelector(BandMath.InvalidHalfWidth.selector, uint16(10_000)));
        band.bandPrices(EUR_USD, 10_000);
    }

    // ---------- bandTicks ----------

    function test_BandTicks_EurUsd() public view {
        // Centre tick 769. 0.5% is about 50 ticks each side: raw edges 719 and 819.
        (int24 lower, int24 upper) = band.bandTicks(EUR_USD, 50, 10, _pair(true));
        assertEq(lower, 710);
        assertEq(upper, 820);
    }

    function test_BandTicks_BaseIsToken1_IsMirrored() public view {
        // Pool price is inverted, so the same band sits at negative ticks.
        (int24 lower, int24 upper) = band.bandTicks(EUR_USD, 50, 10, _pair(false));
        assertEq(lower, -820);
        assertEq(upper, -710);
    }

    function test_BandTicks_NarrowBand_SnapsOutToSpacing() public view {
        // 0.01% each side is about 1 tick, far less than a spacing of 60.
        // The band widens to the nearest spacing on both sides of the centre.
        (int24 lower, int24 upper) = band.bandTicks(1e18, 1, 60, _pair(true));
        assertEq(lower, -60);
        assertEq(upper, 60);
    }

    function test_RevertWhen_TickSpacingNotPositive() public {
        vm.expectRevert(abi.encodeWithSelector(BandMath.InvalidTickSpacing.selector, int24(0)));
        band.bandTicks(EUR_USD, 50, 0, _pair(true));
    }

    function testFuzz_BandTicks_AlignedOrderedAndContainCentre(
        uint256 price,
        uint16 halfWidthBps,
        int24 tickSpacing,
        bool baseIsToken0
    ) public view {
        price = bound(price, 1e12, 1e24);
        halfWidthBps = uint16(bound(halfWidthBps, 1, 5000));
        tickSpacing = int24(bound(tickSpacing, 1, 200));
        Pair memory pair = _pair(baseIsToken0);

        (int24 lower, int24 upper) = band.bandTicks(price, halfWidthBps, tickSpacing, pair);
        int24 centre = FxMath.tickFromPrice(price, pair);

        assertEq(lower % tickSpacing, 0, "lower not aligned");
        assertEq(upper % tickSpacing, 0, "upper not aligned");
        assertLt(lower, upper, "empty band");
        assertLe(lower, centre, "centre below band");
        assertGe(upper, centre, "centre above band");
        assertGe(lower, TickMath.minUsableTick(tickSpacing));
        assertLe(upper, TickMath.maxUsableTick(tickSpacing));
    }

    // ---------- deviation and recenter trigger ----------

    function test_DeviationBps_BothDirections() public view {
        assertEq(band.deviationBps(1.0908e18, EUR_USD), 100); // up 1%
        assertEq(band.deviationBps(1.0692e18, EUR_USD), 100); // down 1%
        assertEq(band.deviationBps(EUR_USD, EUR_USD), 0);
    }

    function test_RevertWhen_ReferenceIsZero() public {
        vm.expectRevert(BandMath.ZeroReference.selector);
        band.deviationBps(EUR_USD, 0);
    }

    function test_NeedsRecenter_AtAndAroundThreshold() public view {
        // Threshold 0.25%.
        assertFalse(band.needsRecenter(1.08216e18, EUR_USD, 25)); // +0.20%
        assertTrue(band.needsRecenter(1.0827e18, EUR_USD, 25)); // +0.25%, exactly at threshold
        assertTrue(band.needsRecenter(1.0746e18, EUR_USD, 25)); // -0.50%
    }

    // ---------- tick rounding ----------

    function test_FloorAndCeil_HandleNegatives() public view {
        assertEq(band.floorToSpacing(769, 10), 760);
        assertEq(band.ceilToSpacing(769, 10), 770);
        assertEq(band.floorToSpacing(-769, 10), -770);
        assertEq(band.ceilToSpacing(-769, 10), -760);
        assertEq(band.floorToSpacing(-770, 10), -770);
        assertEq(band.ceilToSpacing(770, 10), 770);
        assertEq(band.floorToSpacing(0, 10), 0);
    }

    function testFuzz_FloorAndCeil(int24 tick, int24 tickSpacing) public view {
        tick = int24(bound(tick, -800_000, 800_000));
        tickSpacing = int24(bound(tickSpacing, 1, 200));

        int24 floor = band.floorToSpacing(tick, tickSpacing);
        int24 ceil = band.ceilToSpacing(tick, tickSpacing);

        assertEq(floor % tickSpacing, 0);
        assertEq(ceil % tickSpacing, 0);
        assertLe(floor, tick);
        assertGe(ceil, tick);
        assertLt(tick - floor, tickSpacing);
        assertLt(ceil - tick, tickSpacing);
    }
}
