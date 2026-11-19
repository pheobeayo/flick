// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FxMath} from "./FxMath.sol";
import {Pair} from "../types/FlickTypes.sol";

/// @title BandMath
/// @notice Where the vault's liquidity band sits and when it must move. All widths in basis points.
library BandMath {
    error InvalidHalfWidth(uint16 halfWidthBps);
    error InvalidTickSpacing(int24 tickSpacing);
    error ZeroReference();

    uint256 internal constant BPS = 10_000; // 100%

    /// @notice Price edges of a band centred on `price`. 50 bps = 0.5% each side.
    function bandPrices(uint256 price, uint16 halfWidthBps)
        internal
        pure
        returns (uint256 lowerPrice, uint256 upperPrice)
    {
        if (halfWidthBps == 0 || halfWidthBps >= BPS) revert InvalidHalfWidth(halfWidthBps);
        lowerPrice = FullMath.mulDiv(price, BPS - halfWidthBps, BPS);
        upperPrice = FullMath.mulDiv(price, BPS + halfWidthBps, BPS);
    }

    /// @notice Tick range for a band centred on `price`, widened outward to the tick spacing.
    function bandTicks(uint256 price, uint16 halfWidthBps, int24 tickSpacing, Pair memory pair)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        if (tickSpacing <= 0) revert InvalidTickSpacing(tickSpacing);
        (uint256 lowerPrice, uint256 upperPrice) = bandPrices(price, halfWidthBps);

        int24 a = FxMath.tickFromPrice(lowerPrice, pair);
        int24 b = FxMath.tickFromPrice(upperPrice, pair);
        (int24 lo, int24 hi) = a < b ? (a, b) : (b, a);

        // `hi` was rounded down, so step up one tick to keep the true edge inside.
        tickLower = floorToSpacing(lo, tickSpacing);
        tickUpper = ceilToSpacing(hi + 1, tickSpacing);

        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;

        // Clamping can collapse the band; keep it at least one spacing wide.
        if (tickLower >= tickUpper) {
            if (tickLower + tickSpacing <= maxTick) tickUpper = tickLower + tickSpacing;
            else tickLower = tickUpper - tickSpacing;
        }
    }

    /// @notice Distance of `price` from `ref`, in bps of `ref`.
    function deviationBps(uint256 price, uint256 ref) internal pure returns (uint256) {
        if (ref == 0) revert ZeroReference();
        uint256 diff = price > ref ? price - ref : ref - price;
        return FullMath.mulDiv(diff, BPS, ref);
    }

    /// @notice True when `price` has moved at least `thresholdBps` from the band's centre.
    function needsRecenter(uint256 price, uint256 centre, uint16 thresholdBps) internal pure returns (bool) {
        return deviationBps(price, centre) >= thresholdBps;
    }

    /// @notice Largest multiple of `tickSpacing` that is <= `tick`.
    function floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        // Division truncates toward zero; step down for negatives.
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    /// @notice Smallest multiple of `tickSpacing` that is >= `tick`.
    function ceilToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) compressed++;
        return compressed * tickSpacing;
    }
}
