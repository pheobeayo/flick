// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Pair} from "../types/FlickTypes.sol";

/// @title FxMath
/// @notice Converts oracle prices (quote per base, 18 decimals) to and from Uniswap pool prices.
/// @dev Handles token decimals and token order, so the hook never does it by hand.
library FxMath {
    error ZeroPrice();
    error DecimalsTooHigh(uint8 decimals);
    error PriceOutOfRange();

    uint256 internal constant ORACLE_UNIT = 1e18;
    uint8 internal constant MAX_DECIMALS = 18;

    uint256 private constant Q64 = 1 << 64;
    uint256 private constant Q128 = 1 << 128;
    uint256 private constant Q192 = 1 << 192;

    /// @notice Pool sqrt price for an oracle price, rounded down.
    function sqrtPriceX96FromPrice(uint256 price, Pair memory pair) internal pure returns (uint160 sqrtPriceX96) {
        if (price == 0) revert ZeroPrice();
        (uint256 baseUnit, uint256 quoteUnit) = _units(pair);

        // Raw pool price (token1 per token0) as num / den.
        (uint256 num, uint256 den) = pair.baseIsToken0
            ? (price * quoteUnit, ORACLE_UNIT * baseUnit)
            : (ORACLE_UNIT * baseUnit, price * quoteUnit);

        // sqrt(num / den) * 2^96, at the most precise scale that cannot overflow.
        uint256 ratio = num / den;
        uint256 sqrtPrice;
        if (ratio < Q64) {
            sqrtPrice = Math.sqrt(FullMath.mulDiv(num, Q192, den));
        } else if (ratio < Q128) {
            sqrtPrice = Math.sqrt(FullMath.mulDiv(num, Q128, den)) << 32;
        } else {
            revert PriceOutOfRange();
        }

        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) revert PriceOutOfRange();
        sqrtPriceX96 = SafeCast.toUint160(sqrtPrice);
    }

    /// @notice Pool tick for an oracle price, rounded down. Not aligned to tick spacing.
    function tickFromPrice(uint256 price, Pair memory pair) internal pure returns (int24 tick) {
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96FromPrice(price, pair));
    }

    /// @notice Inverse of `sqrtPriceX96FromPrice`, rounded down. Used by tests.
    function priceFromSqrtPriceX96(uint160 sqrtPriceX96, Pair memory pair) internal pure returns (uint256 price) {
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange();
        }
        (uint256 baseUnit, uint256 quoteUnit) = _units(pair);

        // Raw pool price as n / d.
        (uint256 n, uint256 d) = sqrtPriceX96 <= type(uint128).max
            ? (uint256(sqrtPriceX96) * sqrtPriceX96, Q192)
            : (FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q64), Q128);

        if (pair.baseIsToken0) {
            price = FullMath.mulDiv(n, ORACLE_UNIT * baseUnit, d * quoteUnit);
        } else {
            price = FullMath.mulDiv(ORACLE_UNIT * baseUnit, d, n) / quoteUnit;
        }
    }

    /// @notice Raw base amount valued in raw quote units, rounded down.
    function quoteValue(uint256 baseAmount, uint256 price, Pair memory pair) internal pure returns (uint256) {
        (uint256 baseUnit, uint256 quoteUnit) = _units(pair);
        return FullMath.mulDiv(baseAmount, price * quoteUnit, ORACLE_UNIT * baseUnit);
    }

    /// @notice Oracle price at a tick. Used by tests.
    function priceFromTick(int24 tick, Pair memory pair) internal pure returns (uint256 price) {
        price = priceFromSqrtPriceX96(TickMath.getSqrtPriceAtTick(tick), pair);
    }

    function _units(Pair memory pair) private pure returns (uint256 baseUnit, uint256 quoteUnit) {
        if (pair.baseDecimals > MAX_DECIMALS) revert DecimalsTooHigh(pair.baseDecimals);
        if (pair.quoteDecimals > MAX_DECIMALS) revert DecimalsTooHigh(pair.quoteDecimals);
        baseUnit = 10 ** pair.baseDecimals;
        quoteUnit = 10 ** pair.quoteDecimals;
    }
}
