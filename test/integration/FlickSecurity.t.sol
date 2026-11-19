// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {FlickTest} from "../utils/FlickTest.sol";

import {FlickHook} from "../../src/FlickHook.sol";
import {IFxOracle} from "../../src/interfaces/IFxOracle.sol";
import {MockFxOracle} from "../../src/oracles/MockFxOracle.sol";
import {OracleStatus, VaultParams} from "../../src/types/FlickTypes.sol";

/// @dev Regression tests for the second security review.
contract FlickSecurityTest is FlickTest {
    MockFxOracle internal gbpUsd;

    function setUp() public override {
        super.setUp();
        // The guardian has approved a GBP / USD feed for some other vault.
        gbpUsd = new MockFxOracle("GBP / USD", 1.27e18);
        vm.prank(guardian);
        hook.setOracleApproved(address(gbpUsd), true);
    }

    function _queueAndWait(VaultParams memory next) internal {
        vm.prank(curator);
        hook.queueParams(poolId, next);
        vm.warp(block.timestamp + hook.PARAMS_DELAY_SECONDS());
        // Keep both feeds fresh after the wait.
        oracle.setPrice(EUR_USD);
        gbpUsd.setPrice(1.27e18);
    }

    // ---------- Switching the primary oracle ----------

    /// A curator could switch a EUR vault to the GBP feed and sell EURC at the GBP price. Now refused.
    function test_RevertWhen_CuratorSwitchesToAnotherCurrencysFeed() public {
        _createVault(_params());
        VaultParams memory next = _params();
        next.primaryOracle = IFxOracle(address(gbpUsd));
        _queueAndWait(next);

        vm.expectRevert(FlickHook.OracleSwitchTooFar.selector);
        hook.applyParams(poolId);
    }

    /// Moving to a second feed for the same pair still works.
    function test_SwitchToAnotherFeedForTheSamePair() public {
        _createVault(_params());
        MockFxOracle backup = new MockFxOracle("EUR / USD backup", EUR_USD * 1001 / 1000);
        vm.prank(guardian);
        hook.setOracleApproved(address(backup), true);

        VaultParams memory next = _params();
        next.primaryOracle = IFxOracle(address(backup));
        _queueAndWait(next);
        backup.setPrice(EUR_USD * 1001 / 1000);

        hook.applyParams(poolId);
        assertEq(address(hook.getVault(poolId).params.primaryOracle), address(backup));
    }

    function test_RevertWhen_NewFeedReadsZero() public {
        _createVault(_params());
        BrokenOracle broken = new BrokenOracle();
        vm.prank(guardian);
        hook.setOracleApproved(address(broken), true);

        VaultParams memory next = _params();
        next.primaryOracle = IFxOracle(address(broken));
        _queueAndWait(next);

        vm.expectRevert(FlickHook.ZeroOraclePrice.selector);
        hook.applyParams(poolId);
    }

    // ---------- Revoking an oracle ----------

    /// A revoked oracle used to keep pricing existing vaults.
    function test_RevokingPrimaryOracle_HaltsSwaps() public {
        uint256 shares = _createVault(_params());

        vm.prank(guardian);
        hook.setOracleApproved(address(oracle), false);
        oracle.setPrice(EUR_USD * 2); // the feed is now reporting nonsense

        (, OracleStatus status,) = hook.oracleState(poolId);
        assertEq(uint8(status), uint8(OracleStatus.Halted));

        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, true, key, "", address(this), block.timestamp);

        vm.expectRevert(FlickHook.RecenterNotNeeded.selector);
        hook.recenter(key);
        assertEq(hook.getVault(poolId).centrePrice, EUR_USD, "never moved to the bad price");

        // Depositors can still leave.
        vm.prank(curator);
        (uint256 out0, uint256 out1) = hook.withdraw(key, shares, 0, 0, curator, block.timestamp);
        assertApproxEqRel(out0, SEED, 1e12);
        assertApproxEqRel(out1, SEED, 1e12);
    }

    function test_ReapprovingPrimaryOracle_ReopensSwaps() public {
        _createVault(_params());
        vm.startPrank(guardian);
        hook.setOracleApproved(address(oracle), false);
        hook.setOracleApproved(address(oracle), true);
        vm.stopPrank();

        assertEq(_swap(true), SWAP_FEE);
    }

    function test_RevokingSecondaryOracle_HaltsSwaps() public {
        VaultParams memory params = _params();
        params.secondaryOracle = IFxOracle(address(secondOracle));
        _createVault(params);

        vm.prank(guardian);
        hook.setOracleApproved(address(secondOracle), false);

        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, true, key, "", address(this), block.timestamp);
    }

    // ---------- Deadlines ----------

    /// A stuck transaction cannot run later at a worse time.
    function test_RevertWhen_DepositAfterDeadline() public {
        _createVault(_params());
        vm.warp(block.timestamp + 1);
        uint256 deadline = block.timestamp - 1; // one second ago

        vm.prank(alice);
        vm.expectRevert(FlickHook.DeadlinePassed.selector);
        hook.deposit(key, 1e18, type(uint256).max, type(uint256).max, alice, deadline);
    }

    function test_RevertWhen_WithdrawAfterDeadline() public {
        uint256 shares = _createVault(_params());
        vm.warp(block.timestamp + 1);
        uint256 deadline = block.timestamp - 1; // one second ago

        vm.prank(curator);
        vm.expectRevert(FlickHook.DeadlinePassed.selector);
        hook.withdraw(key, shares, 0, 0, curator, deadline);
    }
}

/// @dev An approved adapter whose source has gone dark.
contract BrokenOracle is IFxOracle {
    function latest() external view returns (uint256, uint64) {
        return (0, uint64(block.timestamp));
    }

    function description() external pure returns (string memory) {
        return "broken";
    }
}
