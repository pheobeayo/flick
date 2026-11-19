// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FlickTest} from "../utils/FlickTest.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

import {FlickHook} from "../../src/FlickHook.sol";
import {IFxOracle} from "../../src/interfaces/IFxOracle.sol";
import {FxMath} from "../../src/libraries/FxMath.sol";
import {Vault, VaultParams, PendingParams} from "../../src/types/FlickTypes.sol";

/// @dev Recentering on oracle moves, and the curator and guardian controls.
contract FlickRecenterTest is FlickTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    uint256 internal constant EUR_UP_1PCT = 1.0908e18;
    uint256 internal constant EUR_DOWN_1PCT = 1.0692e18;

    function _valueAtPrice(uint256 price, uint256 amount0, uint256 amount1) internal view returns (uint256) {
        (uint256 base, uint256 quote) = baseIsToken0 ? (amount0, amount1) : (amount1, amount0);
        return quote + base * price / 1e18;
    }

    /// The hook must hold every token its books say it holds.
    function _assertSolvent() internal view {
        Vault memory vault = hook.getVault(poolId);
        (uint256 hook0, uint256 hook1) = baseIsToken0
            ? (eurc.balanceOf(address(hook)), usdc.balanceOf(address(hook)))
            : (usdc.balanceOf(address(hook)), eurc.balanceOf(address(hook)));
        assertGe(hook0, vault.idle0 + vault.curatorFees0, "token0 short");
        assertGe(hook1, vault.idle1 + vault.curatorFees1, "token1 short");
    }

    function _assertCentredOn(uint256 price) internal view {
        Vault memory vault = hook.getVault(poolId);
        assertEq(vault.centrePrice, price, "centre price");
        int24 centreTick = FxMath.tickFromPrice(price, vault.pair);
        assertLe(vault.tickLower, centreTick, "band below centre");
        assertGt(vault.tickUpper, centreTick, "band above centre");
        assertEq(poolManager.getLiquidity(poolId), vault.liquidity, "pool liquidity");
        assertGt(vault.liquidity, 0, "no liquidity");
    }

    // ---------- Recenter on swap ----------

    function test_Recenter_OnSwap_WhenRateRises() public {
        _createVault(_params());
        Vault memory before = hook.getVault(poolId);

        oracle.setPrice(EUR_UP_1PCT);
        _swap(true);

        _assertCentredOn(EUR_UP_1PCT);
        Vault memory afterMove = hook.getVault(poolId);
        assertTrue(afterMove.tickLower != before.tickLower);
        _assertSolvent();
    }

    function test_Recenter_OnSwap_WhenRateFalls() public {
        _createVault(_params());
        oracle.setPrice(EUR_DOWN_1PCT);
        _swap(false);

        _assertCentredOn(EUR_DOWN_1PCT);
        _assertSolvent();
    }

    function test_Recenter_SwapTradesAtTheNewRate() public {
        _createVault(_params());
        oracle.setPrice(EUR_UP_1PCT);

        // Sell 1,000 EURC. At the old rate that paid 1,080 USDC. It must now pay about 1,090.80.
        uint256 usdcBefore = usdc.balanceOf(address(this));
        _swap(baseIsToken0);
        assertApproxEqRel(usdc.balanceOf(address(this)) - usdcBefore, 1090.8e6, 0.002e18);
    }

    function test_NoRecenter_WhenMoveIsBelowThreshold() public {
        _createVault(_params());
        Vault memory before = hook.getVault(poolId);

        // 0.1% move. Threshold is 0.25%.
        oracle.setPrice(EUR_USD * 1001 / 1000);
        _swap(true);

        Vault memory afterSwap = hook.getVault(poolId);
        assertEq(afterSwap.centrePrice, EUR_USD);
        assertEq(afterSwap.tickLower, before.tickLower);
        assertEq(afterSwap.tickUpper, before.tickUpper);
    }

    function test_NoRecenter_WhenFeedIsStale() public {
        _createVault(_params());
        oracle.setPrice(EUR_UP_1PCT);
        vm.warp(block.timestamp + MAX_STALE + 1);

        // The price moved but it is too old to act on: no recenter, no swaps.
        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, true, key, "", address(this), block.timestamp);
        assertEq(hook.getVault(poolId).centrePrice, EUR_USD);
    }

    function test_Recenter_HandlesLargeMove() public {
        VaultParams memory params = _params();
        _createVault(params);

        // 15% jump: the empty pool is moved across about 1,400 ticks.
        uint256 jumped = EUR_USD * 115 / 100;
        oracle.setPrice(jumped);
        _swap(true);

        _assertCentredOn(jumped);
        _assertSolvent();
    }

    function test_Recenter_RepeatedMoves_StaySolvent() public {
        _createVault(_params());
        uint256 price = EUR_USD;
        for (uint256 i = 0; i < 10; i++) {
            price = i % 3 == 0 ? price * 99 / 100 : price * 1008 / 1000;
            oracle.setPrice(price);
            _swapAs(bob, i % 2 == 0, 25_000e6);
            _assertCentredOn(price);
            _assertSolvent();
        }
    }

    // ---------- Public recenter ----------

    function test_Recenter_Public_KeepsEveryToken() public {
        _createVault(_params());
        (uint256 before0, uint256 before1) = hook.totalAssets(poolId);

        oracle.setPrice(EUR_UP_1PCT);
        vm.prank(bob);
        hook.recenter(key);

        // Same tokens, new band. Only rounding dust may differ.
        (uint256 after0, uint256 after1) = hook.totalAssets(poolId);
        assertApproxEqAbs(after0, before0, 3);
        assertApproxEqAbs(after1, before1, 3);
        _assertCentredOn(EUR_UP_1PCT);
        _assertSolvent();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPriceX96, FxMath.sqrtPriceX96FromPrice(EUR_UP_1PCT, hook.getVault(poolId).pair));
    }

    function test_RevertWhen_RecenterNotNeeded() public {
        _createVault(_params());
        vm.expectRevert(FlickHook.RecenterNotNeeded.selector);
        hook.recenter(key);
    }

    function test_RevertWhen_RecenterWithStaleFeed() public {
        _createVault(_params());
        oracle.setPrice(EUR_UP_1PCT);
        vm.warp(block.timestamp + MAX_STALE + 1);
        vm.expectRevert(FlickHook.RecenterNotNeeded.selector);
        hook.recenter(key);
    }

    function test_RevertWhen_RecenterUnknownVault() public {
        vm.expectRevert(FlickHook.VaultNotFound.selector);
        hook.recenter(key);
    }

    function test_DepositAndWithdraw_WorkAfterRecenter() public {
        uint256 curatorShares = _createVault(_params());
        oracle.setPrice(EUR_UP_1PCT);
        hook.recenter(key);

        vm.prank(alice);
        (uint256 paid0, uint256 paid1) =
            hook.deposit(key, 100_000e18, type(uint256).max, type(uint256).max, alice, block.timestamp);
        vm.prank(alice);
        (uint256 got0, uint256 got1) = hook.withdraw(key, 100_000e18, 0, 0, alice, block.timestamp);
        assertLe(got0, paid0);
        assertLe(got1, paid1);

        vm.prank(curator);
        hook.withdraw(key, curatorShares, 0, 0, curator, block.timestamp);
        _assertSolvent();
    }

    // ---------- The point of the project: Flick against a plain pool ----------

    /// Same liquidity, band, 1% move and trade: the plain pool's LP pays the arbitrageur, Flick's does not.
    function test_Arbitrage_PlainPoolLoses_FlickDoesNot() public {
        uint256 curatorShares = _createVault(_params());
        Vault memory vault = hook.getVault(poolId);

        // A plain v4 pool with no hook, holding the same position.
        PoolKey memory plainKey = key;
        plainKey.hooks = IHooks(address(0));
        plainKey.fee = SWAP_FEE;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        poolManager.initialize(plainKey, sqrtPriceX96);
        (uint256 plainTokenId, BalanceDelta plainIn) = positionManager.mint(
            plainKey,
            vault.tickLower,
            vault.tickUpper,
            vault.liquidity,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ""
        );

        // The euro rises 1%. Both pools still show the old price.
        oracle.setPrice(EUR_UP_1PCT);

        // The arbitrageur buys EURC with 200,000 USDC in each pool.
        bool buyEurc = !baseIsToken0;
        uint256 spend = 200_000e6;

        uint256 eurcBefore = eurc.balanceOf(bob);
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens(spend, 0, buyEurc, plainKey, "", bob, block.timestamp);
        uint256 plainWorth = (eurc.balanceOf(bob) - eurcBefore) * EUR_UP_1PCT / 1e18;

        eurcBefore = eurc.balanceOf(bob);
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens(spend, 0, buyEurc, key, "", bob, block.timestamp);
        uint256 flickWorth = (eurc.balanceOf(bob) - eurcBefore) * EUR_UP_1PCT / 1e18;

        // The arbitrageur's EURC, valued at the true rate, against the USDC spent.
        assertGt(plainWorth, spend, "plain pool should be exploitable");
        assertLt(flickWorth, spend, "Flick should not be exploitable");
        emit log_named_decimal_uint("arbitrageur gains from plain pool (USDC)", plainWorth - spend, 6);
        emit log_named_decimal_uint("arbitrageur loses against Flick (USDC)", spend - flickWorth, 6);

        // Each LP against simply holding the tokens they put in, at the true rate.
        uint256 plainHeld = _valueAtPrice(EUR_UP_1PCT, _abs(plainIn.amount0()), _abs(plainIn.amount1()));
        BalanceDelta plainOut = positionManager.burn(plainTokenId, 0, 0, address(this), block.timestamp, "");
        uint256 plainEnd = _valueAtPrice(EUR_UP_1PCT, _abs(plainOut.amount0()), _abs(plainOut.amount1()));

        uint256 flickHeld = _valueAtPrice(EUR_UP_1PCT, SEED, SEED);
        vm.prank(curator);
        (uint256 out0, uint256 out1) = hook.withdraw(key, curatorShares, 0, 0, curator, block.timestamp);
        uint256 flickEnd = _valueAtPrice(EUR_UP_1PCT, out0, out1);

        assertLt(plainEnd, plainHeld, "plain LP should lose to arbitrage");
        assertGe(flickEnd, flickHeld, "Flick LP should not lose");
        emit log_named_decimal_uint("plain pool LP loses (USDC)", plainHeld - plainEnd, 6);
        emit log_named_decimal_uint("Flick LP gains (USDC)", flickEnd - flickHeld, 6);
    }

    function _abs(int128 value) internal pure returns (uint256) {
        return uint256(uint128(value < 0 ? -value : value));
    }

    // ---------- Curator settings ----------

    function test_QueueParams_ApplyAfterDelay() public {
        _createVault(_params());
        VaultParams memory next = _params();
        next.bandHalfWidthBps = 100;
        next.feePips = 200;

        vm.prank(curator);
        hook.queueParams(poolId, next);
        PendingParams memory pending = hook.getPendingParams(poolId);
        assertEq(pending.readyAt, block.timestamp + hook.PARAMS_DELAY_SECONDS());
        assertEq(pending.params.bandHalfWidthBps, 100);

        // Nothing changes until the wait is over.
        assertEq(hook.getVault(poolId).params.bandHalfWidthBps, 50);
        vm.expectRevert(FlickHook.ParamsNotReady.selector);
        hook.applyParams(poolId);

        vm.warp(block.timestamp + hook.PARAMS_DELAY_SECONDS());
        vm.prank(bob); // anyone may apply
        hook.applyParams(poolId);

        assertEq(hook.getVault(poolId).params.bandHalfWidthBps, 100);
        assertEq(hook.getVault(poolId).params.feePips, 200);
        assertEq(hook.getPendingParams(poolId).readyAt, 0);
    }

    function test_AppliedBandWidth_IsUsedAtNextRecenter() public {
        _createVault(_params());
        Vault memory before = hook.getVault(poolId);

        VaultParams memory next = _params();
        next.bandHalfWidthBps = 200; // four times wider
        vm.prank(curator);
        hook.queueParams(poolId, next);
        vm.warp(block.timestamp + hook.PARAMS_DELAY_SECONDS());
        hook.applyParams(poolId);

        oracle.setPrice(EUR_UP_1PCT);
        hook.recenter(key);

        Vault memory afterMove = hook.getVault(poolId);
        assertGt(afterMove.tickUpper - afterMove.tickLower, 3 * (before.tickUpper - before.tickLower));
    }

    function test_RevertWhen_StrangerQueuesParams() public {
        _createVault(_params());
        vm.prank(alice);
        vm.expectRevert(FlickHook.NotCurator.selector);
        hook.queueParams(poolId, _params());
    }

    function test_RevertWhen_ApplyWithNothingQueued() public {
        _createVault(_params());
        vm.expectRevert(FlickHook.ParamsNotReady.selector);
        hook.applyParams(poolId);
    }

    function test_RevertWhen_QueuedParamsBreakProtocolLimits() public {
        _createVault(_params());
        vm.startPrank(curator);

        VaultParams memory params = _params();
        params.bandHalfWidthBps = hook.MAX_BAND_HALF_WIDTH_BPS() + 1;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.queueParams(poolId, params);

        params = _params();
        params.recenterThresholdBps = params.bandHalfWidthBps + 1;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.queueParams(poolId, params);

        params = _params();
        params.feePips = hook.MAX_FEE_PIPS() + 1;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.queueParams(poolId, params);

        params = _params();
        params.performanceFeeBps = hook.MAX_PERFORMANCE_FEE_BPS() + 1;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.queueParams(poolId, params);

        params = _params();
        params.maxStalenessSeconds = hook.MAX_STALENESS_SECONDS() + 1;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.queueParams(poolId, params);

        vm.stopPrank();
    }

    // ---------- Curator fee ----------

    function test_CuratorFee_IsACutOfSwapFees() public {
        VaultParams memory params = _params();
        params.performanceFeeBps = 1000; // 10%
        _createVault(params);

        for (uint256 i = 0; i < 20; i++) {
            _swapAs(bob, true, 50_000e6);
            _swapAs(bob, false, 50_000e6);
        }

        // Any deposit collects the fees first.
        vm.prank(alice);
        hook.deposit(key, 1e18, type(uint256).max, type(uint256).max, alice, block.timestamp);

        Vault memory vault = hook.getVault(poolId);
        assertGt(vault.curatorFees0, 0);
        assertGt(vault.curatorFees1, 0);
        // ~100 of each token in fees; the curator gets 10%.
        assertApproxEqRel(vault.curatorFees0, 10e6, 0.02e18);
        assertApproxEqRel(vault.curatorFees1, 10e6, 0.02e18);
        _assertSolvent();

        uint256 eurcBefore = eurc.balanceOf(curator);
        uint256 usdcBefore = usdc.balanceOf(curator);
        vm.prank(curator);
        (uint256 claimed0, uint256 claimed1) = hook.claimCuratorFees(key, curator);
        assertEq(claimed0, vault.curatorFees0);
        assertEq(claimed1, vault.curatorFees1);
        assertEq(eurc.balanceOf(curator) - eurcBefore + usdc.balanceOf(curator) - usdcBefore, claimed0 + claimed1);

        assertEq(hook.getVault(poolId).curatorFees0, 0);
        assertEq(hook.getVault(poolId).curatorFees1, 0);
        _assertSolvent();
    }

    function test_CuratorFee_AlsoTakenAtRecenter() public {
        VaultParams memory params = _params();
        params.performanceFeeBps = 1000;
        _createVault(params);
        for (uint256 i = 0; i < 10; i++) {
            _swapAs(bob, true, 50_000e6);
            _swapAs(bob, false, 50_000e6);
        }

        oracle.setPrice(EUR_UP_1PCT);
        hook.recenter(key);

        Vault memory vault = hook.getVault(poolId);
        assertGt(vault.curatorFees0 + vault.curatorFees1, 0);
        _assertSolvent();
    }

    function test_RevertWhen_StrangerClaimsCuratorFees() public {
        _createVault(_params());
        vm.prank(alice);
        vm.expectRevert(FlickHook.NotCurator.selector);
        hook.claimCuratorFees(key, alice);
    }

    // ---------- Guardian pause ----------

    function test_Pause_StopsSwapsAndDeposits_NotWithdrawals() public {
        uint256 curatorShares = _createVault(_params());
        vm.prank(guardian);
        hook.setPaused(poolId, true);

        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.VaultPaused.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, true, key, "", address(this), block.timestamp);

        vm.prank(alice);
        vm.expectRevert(FlickHook.VaultPaused.selector);
        hook.deposit(key, 1e18, type(uint256).max, type(uint256).max, alice, block.timestamp);

        vm.prank(curator);
        (uint256 out0, uint256 out1) = hook.withdraw(key, curatorShares, 0, 0, curator, block.timestamp);
        assertApproxEqRel(out0, SEED, 1e12);
        assertApproxEqRel(out1, SEED, 1e12);
    }

    function test_Unpause_ResumesSwaps() public {
        _createVault(_params());
        vm.startPrank(guardian);
        hook.setPaused(poolId, true);
        hook.setPaused(poolId, false);
        vm.stopPrank();
        assertEq(_swap(true), SWAP_FEE);
    }

    function test_RevertWhen_StrangerPauses() public {
        _createVault(_params());
        vm.expectRevert(FlickHook.NotGuardian.selector);
        hook.setPaused(poolId, true);
    }

    function test_RevertWhen_PausingUnknownVault() public {
        vm.prank(guardian);
        vm.expectRevert(FlickHook.VaultNotFound.selector);
        hook.setPaused(poolId, true);
    }

    function test_RevertWhen_RecenterWhilePaused() public {
        _createVault(_params());
        oracle.setPrice(EUR_UP_1PCT);
        vm.prank(guardian);
        hook.setPaused(poolId, true);

        vm.expectRevert(FlickHook.VaultPaused.selector);
        hook.recenter(key);
    }

    // ---------- Audit regressions ----------

    /// An oracle that loses its approval during the wait can no longer be applied.
    function test_RevertWhen_ApplyingParamsWithRevokedOracle() public {
        _createVault(_params());
        VaultParams memory next = _params();
        next.secondaryOracle = IFxOracle(address(secondOracle));

        vm.prank(curator);
        hook.queueParams(poolId, next);
        vm.prank(guardian);
        hook.setOracleApproved(address(secondOracle), false);

        vm.warp(block.timestamp + hook.PARAMS_DELAY_SECONDS());
        vm.expectRevert(abi.encodeWithSelector(FlickHook.OracleNotApproved.selector, address(secondOracle)));
        hook.applyParams(poolId);
    }

    /// A move just under a loose threshold was free money; at the tightest threshold it loses.
    function test_Arbitrage_SmallMove_LosesWithTightThreshold() public {
        VaultParams memory params = _params();
        params.recenterThresholdBps = 1;
        _createVault(params);

        uint256 moved = EUR_USD * 10_024 / 10_000; // +0.24%
        oracle.setPrice(moved);

        uint256 spend = 200_000e6;
        uint256 eurcBefore = eurc.balanceOf(bob);
        _swapAs(bob, !baseIsToken0, spend);
        uint256 worth = (eurc.balanceOf(bob) - eurcBefore) * moved / 1e18;

        assertLt(worth, spend, "small move should not be exploitable");
    }

    /// Feed dies over a weekend and the rate gaps 2%: nobody can trade the old price.
    function test_Arbitrage_WeekendGap_CannotTradeWhileHalted() public {
        _createVault(_params());
        _swapAs(alice, baseIsToken0, 1000e6); // leave the pool just below its centre
        vm.warp(block.timestamp + MAX_STALE + 1);

        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens(400_000e6, 0, !baseIsToken0, key, "", bob, block.timestamp);
    }

    // ---------- Fuzz ----------

    /// Any rate move, then any swap: the band follows the rate and the books balance.
    function testFuzz_RateMoveThenSwap_StaysCentredAndSolvent(uint256 moveBps, bool up, uint256 swapIn, bool zeroForOne)
        public
    {
        VaultParams memory params = _params();
        params.performanceFeeBps = 1000;
        _createVault(params);

        moveBps = bound(moveBps, 0, 1500);
        swapIn = bound(swapIn, 1e6, 300_000e6);
        uint256 price = up ? EUR_USD * (10_000 + moveBps) / 10_000 : EUR_USD * (10_000 - moveBps) / 10_000;

        // Some trading before the move so there are fees to account for.
        _swapAs(bob, true, 40_000e6);
        _swapAs(bob, false, 40_000e6);

        oracle.setPrice(price);
        _swapAs(bob, zeroForOne, swapIn);

        if (moveBps >= params.recenterThresholdBps) _assertCentredOn(price);
        else assertEq(hook.getVault(poolId).centrePrice, EUR_USD);
        _assertSolvent();
    }

    /// A recenter on its own never changes what the vault holds by more than rounding dust.
    function testFuzz_Recenter_ConservesTokens(uint256 moveBps, bool up, uint256 swapIn, bool zeroForOne) public {
        _createVault(_params());
        moveBps = bound(moveBps, 25, 1500);
        swapIn = bound(swapIn, 1e6, 300_000e6);
        uint256 price = up ? EUR_USD * (10_000 + moveBps) / 10_000 : EUR_USD * (10_000 - moveBps) / 10_000;

        // Leave the pool off-centre first.
        _swapAs(bob, zeroForOne, swapIn);

        // Collect fees so both snapshots count them.
        vm.prank(alice);
        hook.deposit(key, 1e18, type(uint256).max, type(uint256).max, alice, block.timestamp);
        (uint256 before0, uint256 before1) = hook.totalAssets(poolId);

        oracle.setPrice(price);
        hook.recenter(key);

        (uint256 after0, uint256 after1) = hook.totalAssets(poolId);
        assertApproxEqAbs(after0, before0, 3);
        assertApproxEqAbs(after1, before1, 3);
        _assertSolvent();
    }
}
