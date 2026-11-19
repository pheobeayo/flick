// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FxMath} from "../../src/libraries/FxMath.sol";
import {Pair} from "../../src/types/FlickTypes.sol";

/// @dev Exposes the library through external calls so reverts can be tested.
contract FxMathHarness {
    function sqrtPriceX96FromPrice(uint256 price, Pair memory pair) external pure returns (uint160) {
        return FxMath.sqrtPriceX96FromPrice(price, pair);
    }

    function tickFromPrice(uint256 price, Pair memory pair) external pure returns (int24) {
        return FxMath.tickFromPrice(price, pair);
    }

    function priceFromSqrtPriceX96(uint160 sqrtPriceX96, Pair memory pair) external pure returns (uint256) {
        return FxMath.priceFromSqrtPriceX96(sqrtPriceX96, pair);
    }

    function priceFromTick(int24 tick, Pair memory pair) external pure returns (uint256) {
        return FxMath.priceFromTick(tick, pair);
    }

    function quoteValue(uint256 baseAmount, uint256 price, Pair memory pair) external pure returns (uint256) {
        return FxMath.quoteValue(baseAmount, price, pair);
    }
}

contract FxMathTest is Test {
    FxMathHarness internal fx;

    uint256 internal constant EUR_USD = 1.08e18;
    uint256 internal constant NGN_USD = 6.8e14; // 1 cNGN = 0.00068 USDC

    // Relative tolerance for round trips: 1e-6 (1e18 = 100%).
    uint256 internal constant TOLERANCE = 1e12;

    function setUp() public {
        fx = new FxMathHarness();
    }

    function _pair(uint8 baseDecimals, uint8 quoteDecimals, bool baseIsToken0) internal pure returns (Pair memory) {
        return Pair({baseDecimals: baseDecimals, quoteDecimals: quoteDecimals, baseIsToken0: baseIsToken0});
    }

    function test_Parity_SameDecimals_IsTickZero() public view {
        assertEq(fx.sqrtPriceX96FromPrice(1e18, _pair(6, 6, true)), uint160(1 << 96));
        assertEq(fx.tickFromPrice(1e18, _pair(6, 6, true)), 0);
        assertEq(fx.tickFromPrice(1e18, _pair(6, 6, false)), 0);
    }

    function test_EurUsd_BaseIsToken0() public view {
        // ln(1.08) / ln(1.0001) = 769.65, rounded down.
        assertEq(fx.tickFromPrice(EUR_USD, _pair(6, 6, true)), 769);
    }

    function test_EurUsd_BaseIsToken1_TickIsMirrored() public view {
        // Pool price is the inverse (USDC per EURC becomes EURC per USDC): -769.65, rounded down.
        assertEq(fx.tickFromPrice(EUR_USD, _pair(6, 6, false)), -770);
    }

    function test_DecimalsShiftTheTick() public view {
        // 1:1 price, base has 18 decimals, quote has 6. Raw pool price is 1e-12.
        // ln(1e-12) / ln(1.0001) = -276324.03, rounded down.
        assertEq(fx.tickFromPrice(1e18, _pair(18, 6, true)), -276325);
        // Flip the order and the raw price is 1e12.
        assertEq(fx.tickFromPrice(1e18, _pair(18, 6, false)), 276324);
    }

    function test_RoundTrip_EurUsd() public view {
        Pair memory pair = _pair(6, 6, true);
        uint256 back = fx.priceFromSqrtPriceX96(fx.sqrtPriceX96FromPrice(EUR_USD, pair), pair);
        assertApproxEqRel(back, EUR_USD, TOLERANCE);
    }

    function test_RoundTrip_NgnScale_MixedDecimals_BothOrders() public view {
        Pair memory a = _pair(18, 6, true);
        Pair memory b = _pair(18, 6, false);
        assertApproxEqRel(fx.priceFromSqrtPriceX96(fx.sqrtPriceX96FromPrice(NGN_USD, a), a), NGN_USD, TOLERANCE);
        assertApproxEqRel(fx.priceFromSqrtPriceX96(fx.sqrtPriceX96FromPrice(NGN_USD, b), b), NGN_USD, TOLERANCE);
    }

    function test_QuoteValue_SameDecimals() public view {
        // 1,000 EURC at 1.08 is 1,080 USDC.
        assertEq(fx.quoteValue(1000e6, EUR_USD, _pair(6, 6, true)), 1080e6);
        // Token order does not change a value.
        assertEq(fx.quoteValue(1000e6, EUR_USD, _pair(6, 6, false)), 1080e6);
    }

    function test_QuoteValue_MixedDecimals() public view {
        // 1,000,000 cNGN (18 decimals) at 0.00068 is 680 USDC (6 decimals).
        assertEq(fx.quoteValue(1_000_000e18, NGN_USD, _pair(18, 6, true)), 680e6);
    }

    function test_HigherPrice_MovesTickUp_WhenBaseIsToken0() public view {
        Pair memory pair = _pair(6, 6, true);
        assertGt(fx.tickFromPrice(EUR_USD * 101 / 100, pair), fx.tickFromPrice(EUR_USD, pair));
    }

    function test_HigherPrice_MovesTickDown_WhenBaseIsToken1() public view {
        Pair memory pair = _pair(6, 6, false);
        assertLt(fx.tickFromPrice(EUR_USD * 101 / 100, pair), fx.tickFromPrice(EUR_USD, pair));
    }

    // ---------- Reverts ----------

    function test_RevertWhen_ZeroPrice() public {
        vm.expectRevert(FxMath.ZeroPrice.selector);
        fx.sqrtPriceX96FromPrice(0, _pair(6, 6, true));
    }

    function test_RevertWhen_BaseDecimalsTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FxMath.DecimalsTooHigh.selector, uint8(19)));
        fx.sqrtPriceX96FromPrice(1e18, _pair(19, 6, true));
    }

    function test_RevertWhen_QuoteDecimalsTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FxMath.DecimalsTooHigh.selector, uint8(19)));
        fx.priceFromSqrtPriceX96(uint160(1 << 96), _pair(6, 19, true));
    }

    function test_RevertWhen_PriceTooHighForPool() public {
        vm.expectRevert(FxMath.PriceOutOfRange.selector);
        fx.sqrtPriceX96FromPrice(1e45, _pair(0, 18, true));
    }

    function test_RevertWhen_PriceTooLowForPool() public {
        vm.expectRevert(FxMath.PriceOutOfRange.selector);
        fx.sqrtPriceX96FromPrice(1e45, _pair(0, 18, false));
    }

    function test_RevertWhen_SqrtPriceOutOfRange() public {
        vm.expectRevert(FxMath.PriceOutOfRange.selector);
        fx.priceFromSqrtPriceX96(TickMath.MIN_SQRT_PRICE - 1, _pair(6, 6, true));
        vm.expectRevert(FxMath.PriceOutOfRange.selector);
        fx.priceFromSqrtPriceX96(TickMath.MAX_SQRT_PRICE, _pair(6, 6, true));
    }

    // ---------- Fuzz ----------

    /// Price -> sqrt price -> price comes back within 0.0001%.
    function testFuzz_RoundTrip_Price(uint256 price, uint8 baseDecimals, uint8 quoteDecimals, bool baseIsToken0)
        public
        view
    {
        price = bound(price, 1e9, 1e30); // 0.000000001 to 1,000,000,000,000
        Pair memory pair = _pair(uint8(bound(baseDecimals, 0, 18)), uint8(bound(quoteDecimals, 0, 18)), baseIsToken0);

        uint256 back = fx.priceFromSqrtPriceX96(fx.sqrtPriceX96FromPrice(price, pair), pair);
        assertApproxEqRel(back, price, TOLERANCE);
    }

    /// The price sits between the returned tick and the next one.
    function testFuzz_TickBracketsPrice(uint256 price, uint8 baseDecimals, uint8 quoteDecimals, bool baseIsToken0)
        public
        view
    {
        price = bound(price, 1e9, 1e30);
        Pair memory pair = _pair(uint8(bound(baseDecimals, 0, 18)), uint8(bound(quoteDecimals, 0, 18)), baseIsToken0);

        int24 tick = fx.tickFromPrice(price, pair);
        uint256 atTick = fx.priceFromTick(tick, pair);
        uint256 atNext = fx.priceFromTick(tick + 1, pair);
        (uint256 low, uint256 high) = atTick < atNext ? (atTick, atNext) : (atNext, atTick);

        uint256 slack = price / 1e6 + 1;
        assertLe(low, price + slack);
        assertGe(high + slack, price);
    }

    /// A higher oracle price never moves the tick the wrong way.
    function testFuzz_Monotonic(uint256 price, uint256 bump, bool baseIsToken0) public view {
        price = bound(price, 1e9, 1e29);
        bump = bound(bump, 1, price);
        Pair memory pair = _pair(6, 6, baseIsToken0);

        int24 before = fx.tickFromPrice(price, pair);
        int24 afterBump = fx.tickFromPrice(price + bump, pair);
        if (baseIsToken0) assertGe(afterBump, before);
        else assertLe(afterBump, before);
    }
}
