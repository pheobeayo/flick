// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {FlickTest} from "../utils/FlickTest.sol";

import {FlickHook} from "../../src/FlickHook.sol";
import {Vault} from "../../src/types/FlickTypes.sol";

/// @dev Seed, deposit, withdraw and share accounting.
contract FlickVaultTest is FlickTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// Value of one whole share in USDC units (6 decimals) at EUR_USD, from collected state.
    function _sharePrice() internal view returns (uint256) {
        (uint256 amount0, uint256 amount1) = hook.totalAssets(poolId);
        return _valueAt(EUR_USD, amount0, amount1) * 1e18 / hook.getVault(poolId).totalShares;
    }

    function _deposit(address who, uint256 shares) internal returns (uint256 amount0, uint256 amount1) {
        vm.prank(who);
        return hook.deposit(key, shares, type(uint256).max, type(uint256).max, who, block.timestamp);
    }

    function _withdraw(address who, uint256 shares) internal returns (uint256 amount0, uint256 amount1) {
        vm.prank(who);
        return hook.withdraw(key, shares, 0, 0, who, block.timestamp);
    }

    // ---------- Seed ----------

    function test_Seed_MintsSharesAtOracleValue() public {
        uint256 eurcBefore = eurc.balanceOf(curator);
        uint256 usdcBefore = usdc.balanceOf(curator);

        uint256 shares = _createVault(_params());

        // 1,000,000 EURC at 1.08 plus 1,000,000 USDC = 2,080,000 USD. One share starts at 1 USD.
        Vault memory vault = hook.getVault(poolId);
        assertEq(vault.totalShares, 2_080_000e18);
        assertEq(shares, 2_080_000e18 - hook.MINIMUM_SHARES());
        assertEq(hook.sharesOf(poolId, curator), shares);
        assertEq(hook.sharesOf(poolId, DEAD), hook.MINIMUM_SHARES());

        assertEq(eurcBefore - eurc.balanceOf(curator), SEED);
        assertEq(usdcBefore - usdc.balanceOf(curator), SEED);
    }

    function test_Seed_PutsLiquidityInTheBand() public {
        _createVault(_params());
        Vault memory vault = hook.getVault(poolId);

        assertGt(vault.liquidity, 0);
        assertEq(poolManager.getLiquidity(poolId), vault.liquidity);
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        assertLe(vault.tickLower, tick);
        assertGt(vault.tickUpper, tick);

        // Nothing is lost between wallet and vault.
        (uint256 amount0, uint256 amount1) = hook.totalAssets(poolId);
        assertApproxEqAbs(amount0, SEED, 2);
        assertApproxEqAbs(amount1, SEED, 2);
        assertApproxEqRel(_sharePrice(), 1e6, 1e12);
    }

    function test_RevertWhen_SeedTooSmall() public {
        vm.prank(curator);
        vm.expectRevert(FlickHook.SeedTooSmall.selector);
        hook.createVault(key, baseIsToken0, _params(), 0, 0);
    }

    // ---------- Deposit ----------

    function test_Deposit_PaysTheVaultsRatio() public {
        _createVault(_params());
        uint256 totalBefore = hook.getVault(poolId).totalShares;

        // Mint 10% of the supply: pay 10% of each holding.
        uint256 shares = totalBefore / 10;
        (uint256 amount0, uint256 amount1) = _deposit(alice, shares);

        assertApproxEqAbs(amount0, SEED / 10, 3);
        assertApproxEqAbs(amount1, SEED / 10, 3);
        assertEq(hook.sharesOf(poolId, alice), shares);
        assertEq(hook.getVault(poolId).totalShares, totalBefore + shares);
    }

    function test_Deposit_MatchesPreview() public {
        _createVault(_params());
        (uint256 preview0, uint256 preview1) = hook.previewDeposit(poolId, 1000e18);
        (uint256 amount0, uint256 amount1) = _deposit(alice, 1000e18);
        assertApproxEqAbs(amount0, preview0, 2);
        assertApproxEqAbs(amount1, preview1, 2);
    }

    function test_Deposit_CanMintToSomeoneElse() public {
        _createVault(_params());
        vm.prank(alice);
        hook.deposit(key, 1000e18, type(uint256).max, type(uint256).max, bob, block.timestamp);
        assertEq(hook.sharesOf(poolId, bob), 1000e18);
        assertEq(hook.sharesOf(poolId, alice), 0);
    }

    function test_Deposit_NeverLowersSharePrice() public {
        _createVault(_params());
        uint256 priceBefore = _sharePrice();
        _deposit(alice, 123_456e18);
        assertGe(_sharePrice(), priceBefore);
    }

    function test_RevertWhen_DepositCostsMoreThanMax() public {
        _createVault(_params());
        (uint256 preview0, uint256 preview1) = hook.previewDeposit(poolId, 1000e18);
        vm.prank(alice);
        vm.expectRevert(FlickHook.SlippageExceeded.selector);
        hook.deposit(key, 1000e18, preview0 / 2, preview1, alice, block.timestamp);
    }

    function test_RevertWhen_DepositZeroShares() public {
        _createVault(_params());
        vm.prank(alice);
        vm.expectRevert(FlickHook.ZeroShares.selector);
        hook.deposit(key, 0, type(uint256).max, type(uint256).max, alice, block.timestamp);
    }

    function test_RevertWhen_DepositToZeroAddress() public {
        _createVault(_params());
        vm.prank(alice);
        vm.expectRevert(FlickHook.ZeroAddress.selector);
        hook.deposit(key, 1e18, type(uint256).max, type(uint256).max, address(0), block.timestamp);
    }

    function test_RevertWhen_DepositIntoUnknownVault() public {
        vm.prank(alice);
        vm.expectRevert(FlickHook.VaultNotFound.selector);
        hook.deposit(key, 1e18, type(uint256).max, type(uint256).max, alice, block.timestamp);
    }

    // ---------- Withdraw ----------

    function test_Withdraw_ReturnsProRataShare() public {
        uint256 shares = _createVault(_params());

        // Curator burns half their shares: gets half of each token back.
        (uint256 amount0, uint256 amount1) = _withdraw(curator, shares / 2);

        assertApproxEqRel(amount0, SEED / 2, 1e12);
        assertApproxEqRel(amount1, SEED / 2, 1e12);
        assertEq(hook.sharesOf(poolId, curator), shares - shares / 2);
    }

    function test_Withdraw_SendsTokensToReceiver() public {
        uint256 shares = _createVault(_params());
        uint256 bobEurc = eurc.balanceOf(bob);
        uint256 bobUsdc = usdc.balanceOf(bob);

        vm.prank(curator);
        (uint256 amount0, uint256 amount1) = hook.withdraw(key, shares / 4, 0, 0, bob, block.timestamp);

        (uint256 eurcOut, uint256 usdcOut) = baseIsToken0 ? (amount0, amount1) : (amount1, amount0);
        assertEq(eurc.balanceOf(bob) - bobEurc, eurcOut);
        assertEq(usdc.balanceOf(bob) - bobUsdc, usdcOut);
    }

    function test_Withdraw_EverythingLeavesOnlyLockedMinimum() public {
        uint256 shares = _createVault(_params());
        _withdraw(curator, shares);

        Vault memory vault = hook.getVault(poolId);
        assertEq(vault.totalShares, hook.MINIMUM_SHARES());
        assertEq(hook.sharesOf(poolId, curator), 0);
    }

    function test_Withdraw_WorksWhenOracleIsDead() public {
        uint256 shares = _createVault(_params());

        // A month with no oracle update. Swaps are halted, exits are not.
        vm.warp(block.timestamp + 30 days);
        (uint256 amount0, uint256 amount1) = _withdraw(curator, shares);

        assertApproxEqRel(amount0, SEED, 1e12);
        assertApproxEqRel(amount1, SEED, 1e12);
    }

    function test_RevertWhen_WithdrawMoreThanOwned() public {
        _createVault(_params());
        vm.prank(alice);
        vm.expectRevert(FlickHook.InsufficientShares.selector);
        hook.withdraw(key, 1e18, 0, 0, alice, block.timestamp);
    }

    function test_RevertWhen_WithdrawBelowMinimumOut() public {
        uint256 shares = _createVault(_params());
        vm.prank(curator);
        vm.expectRevert(FlickHook.SlippageExceeded.selector);
        hook.withdraw(key, shares / 2, SEED, SEED, curator, block.timestamp);
    }

    function test_RevertWhen_WithdrawZeroShares() public {
        _createVault(_params());
        vm.prank(curator);
        vm.expectRevert(FlickHook.ZeroShares.selector);
        hook.withdraw(key, 0, 0, 0, curator, block.timestamp);
    }

    // ---------- Fees ----------

    function test_SwapFees_RaiseSharePriceForHolders() public {
        _createVault(_params());
        uint256 aliceShares = 100_000e18;
        _deposit(alice, aliceShares);
        uint256 aliceValueBefore = _walletValue(alice);

        // Trade back and forth so the price ends near where it started and fees pile up.
        for (uint256 i = 0; i < 20; i++) {
            _swapAs(bob, true, 50_000e6);
            _swapAs(bob, false, 50_000e6);
        }

        // Alice leaves with more than she would have before the trading.
        (uint256 preview0, uint256 preview1) = hook.previewDeposit(poolId, aliceShares);
        (uint256 amount0, uint256 amount1) = _withdraw(alice, aliceShares);
        assertGt(_valueAt(EUR_USD, amount0, amount1), _valueAt(EUR_USD, preview0, preview1));
        assertGt(_walletValue(alice), aliceValueBefore);
    }

    function test_LateDepositor_DoesNotGetEarlierFees() public {
        _createVault(_params());
        for (uint256 i = 0; i < 20; i++) {
            _swapAs(bob, true, 50_000e6);
            _swapAs(bob, false, 50_000e6);
        }

        // Alice joins after the fees were earned, then leaves straight away.
        uint256 valueBefore = _walletValue(alice);
        _deposit(alice, 100_000e18);
        _withdraw(alice, 100_000e18);

        assertLe(_walletValue(alice), valueBefore);
    }

    // ---------- Safety ----------

    function test_RevertWhen_StrangerCallsUnlockCallback() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    /// Push the pool price, deposit, push it back, withdraw. The attacker must not come out ahead.
    function test_PriceManipulationAroundDeposit_IsNotProfitable() public {
        _createVault(_params());
        uint256 valueBefore = _walletValue(alice);
        uint256 curatorClaimBefore = _sharePrice();

        _swapAs(alice, true, 400_000e6);
        _deposit(alice, 500_000e18);
        _swapAs(alice, false, 400_000e6);
        _withdraw(alice, 500_000e18);

        assertLt(_walletValue(alice), valueBefore);
        assertGe(_sharePrice(), curatorClaimBefore);
    }

    function test_TwoVaults_KeepSeparateBooks() public {
        _createVault(_params());

        // Same hook, same tokens, different tick spacing: a second pool and vault.
        PoolKey memory otherKey = _key(60);
        PoolId otherId = otherKey.toId();
        vm.prank(bob);
        hook.createVault(otherKey, baseIsToken0, _params(), 5000e6, 5000e6);

        assertEq(hook.getVault(otherId).curator, bob);
        assertEq(hook.getVault(otherId).totalShares, 10_400e18);
        assertEq(hook.getVault(poolId).totalShares, 2_080_000e18);

        // Bob's full exit from his vault takes only his vault's tokens.
        (uint256 before0, uint256 before1) = hook.totalAssets(poolId);
        uint256 bobShares = hook.sharesOf(otherId, bob);
        vm.prank(bob);
        (uint256 out0, uint256 out1) = hook.withdraw(otherKey, bobShares, 0, 0, bob, block.timestamp);
        assertLe(out0, 5000e6);
        assertLe(out1, 5000e6);

        (uint256 after0, uint256 after1) = hook.totalAssets(poolId);
        assertEq(after0, before0);
        assertEq(after1, before1);
    }

    // ---------- Fuzz ----------

    /// Deposit then withdraw the same shares: never get back more than was paid, of either token.
    function testFuzz_DepositThenWithdraw_NeverProfits(uint256 shares, uint256 swapIn, bool zeroForOne) public {
        _createVault(_params());
        shares = bound(shares, 1, 5_000_000e18);
        swapIn = bound(swapIn, 1e6, 400_000e6);

        // Move the pool somewhere inside the band first.
        _swapAs(bob, zeroForOne, swapIn);

        (uint256 paid0, uint256 paid1) = _deposit(alice, shares);
        (uint256 got0, uint256 got1) = _withdraw(alice, shares);

        assertLe(got0, paid0);
        assertLe(got1, paid1);
    }

    /// Other people's deposits and withdrawals never reduce what an existing holder can withdraw.
    function testFuzz_OthersComingAndGoing_NeverHurtsHolder(
        uint256 depositShares,
        uint256 withdrawShares,
        uint256 swapIn
    ) public {
        uint256 curatorShares = _createVault(_params());
        depositShares = bound(depositShares, 1, 5_000_000e18);
        withdrawShares = bound(withdrawShares, 1, depositShares);
        swapIn = bound(swapIn, 1e6, 400_000e6);
        _swapAs(bob, true, swapIn);

        // What the curator could withdraw right now.
        uint256 snapshot = vm.snapshotState();
        (uint256 before0, uint256 before1) = _withdraw(curator, curatorShares);
        vm.revertToState(snapshot);

        _deposit(alice, depositShares);
        _withdraw(alice, withdrawShares);

        (uint256 after0, uint256 after1) = _withdraw(curator, curatorShares);
        assertGe(after0, before0);
        assertGe(after1, before1);
    }

    /// The hook always holds at least the idle tokens it has on its books.
    function testFuzz_HookHoldsItsIdleBalance(uint256 shares, uint256 swapIn, bool zeroForOne) public {
        _createVault(_params());
        shares = bound(shares, 1, 5_000_000e18);
        swapIn = bound(swapIn, 1e6, 400_000e6);

        _deposit(alice, shares);
        _swapAs(bob, zeroForOne, swapIn);
        _withdraw(alice, (shares + 1) / 2);

        Vault memory vault = hook.getVault(poolId);
        (uint256 hook0, uint256 hook1) = baseIsToken0
            ? (eurc.balanceOf(address(hook)), usdc.balanceOf(address(hook)))
            : (usdc.balanceOf(address(hook)), eurc.balanceOf(address(hook)));
        assertGe(hook0, vault.idle0);
        assertGe(hook1, vault.idle1);
    }
}
