// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FlickTest} from "../utils/FlickTest.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";

import {FlickHook} from "../../src/FlickHook.sol";
import {IFxOracle} from "../../src/interfaces/IFxOracle.sol";
import {MockFxOracle} from "../../src/oracles/MockFxOracle.sol";
import {FxMath} from "../../src/libraries/FxMath.sol";
import {Vault, VaultParams, OracleStatus} from "../../src/types/FlickTypes.sol";

/// @dev Vault creation, the gates, and the oracle-driven fee.
contract FlickHookTest is FlickTest {
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    // ---------- Guardian ----------

    function test_SetOracleApproved_ByGuardian() public {
        address newOracle = makeAddr("newOracle");
        vm.prank(guardian);
        hook.setOracleApproved(newOracle, true);
        assertTrue(hook.approvedOracles(newOracle));
    }

    function test_RevertWhen_StrangerApprovesOracle() public {
        vm.expectRevert(FlickHook.NotGuardian.selector);
        hook.setOracleApproved(makeAddr("newOracle"), true);
    }

    function test_RevertWhen_ApprovingZeroAddress() public {
        vm.prank(guardian);
        vm.expectRevert(FlickHook.ZeroAddress.selector);
        hook.setOracleApproved(address(0), true);
    }

    // ---------- createVault ----------

    function test_CreateVault_StartsPoolAtOraclePrice() public {
        _createVault(_params());

        Vault memory vault = hook.getVault(poolId);
        assertEq(vault.curator, curator);
        assertEq(vault.centrePrice, EUR_USD);
        assertEq(vault.pair.baseDecimals, 6);
        assertEq(vault.pair.quoteDecimals, 6);
        assertEq(vault.pair.baseIsToken0, baseIsToken0);

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPriceX96, FxMath.sqrtPriceX96FromPrice(EUR_USD, vault.pair));
        assertEq(tick, baseIsToken0 ? int24(769) : int24(-770));
    }

    function test_RevertWhen_VaultAlreadyExists() public {
        _createVault(_params());
        vm.expectRevert(FlickHook.VaultAlreadyExists.selector);
        hook.createVault(key, baseIsToken0, _params(), SEED, SEED);
    }

    function test_RevertWhen_KeyPointsAtAnotherHook() public {
        key.hooks = IHooks(address(0));
        vm.expectRevert(FlickHook.WrongHook.selector);
        hook.createVault(key, baseIsToken0, _params(), SEED, SEED);
    }

    function test_RevertWhen_FeeIsNotDynamic() public {
        key.fee = 3000;
        vm.expectRevert(FlickHook.FeeNotDynamic.selector);
        hook.createVault(key, baseIsToken0, _params(), SEED, SEED);
    }

    function test_RevertWhen_NativeCurrency() public {
        key.currency0 = Currency.wrap(address(0));
        vm.expectRevert(FlickHook.NativeCurrencyNotSupported.selector);
        hook.createVault(key, baseIsToken0, _params(), SEED, SEED);
    }

    function test_RevertWhen_OracleNotApproved() public {
        MockFxOracle rogue = new MockFxOracle("rogue", EUR_USD);
        VaultParams memory params = _params();
        params.primaryOracle = IFxOracle(address(rogue));
        vm.expectRevert(abi.encodeWithSelector(FlickHook.OracleNotApproved.selector, address(rogue)));
        hook.createVault(key, baseIsToken0, params, SEED, SEED);
    }

    function test_RevertWhen_SecondaryOracleNotApproved() public {
        MockFxOracle rogue = new MockFxOracle("rogue", EUR_USD);
        VaultParams memory params = _params();
        params.secondaryOracle = IFxOracle(address(rogue));
        vm.expectRevert(abi.encodeWithSelector(FlickHook.OracleNotApproved.selector, address(rogue)));
        hook.createVault(key, baseIsToken0, params, SEED, SEED);
    }

    function test_RevertWhen_OracleStaleAtCreation() public {
        vm.warp(block.timestamp + MAX_STALE + 1);
        vm.expectRevert(FlickHook.OracleNotFresh.selector);
        hook.createVault(key, baseIsToken0, _params(), SEED, SEED);
    }

    function test_RevertWhen_ParamsInvalid() public {
        VaultParams memory params = _params();
        params.bandHalfWidthBps = 0;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.createVault(key, baseIsToken0, params, SEED, SEED);

        params = _params();
        params.recenterThresholdBps = 0;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.createVault(key, baseIsToken0, params, SEED, SEED);

        params = _params();
        params.feePips = LPFeeLibrary.MAX_LP_FEE + 1;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.createVault(key, baseIsToken0, params, SEED, SEED);

        params = _params();
        params.maxStalenessSeconds = 0;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.createVault(key, baseIsToken0, params, SEED, SEED);

        params = _params();
        params.secondaryOracle = params.primaryOracle;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.createVault(key, baseIsToken0, params, SEED, SEED);

        params = _params();
        params.secondaryOracle = IFxOracle(address(secondOracle));
        params.maxDivergenceBps = 0;
        vm.expectRevert(FlickHook.InvalidParams.selector);
        hook.createVault(key, baseIsToken0, params, SEED, SEED);
    }

    // ---------- Gates ----------

    function test_RevertWhen_PoolInitializedDirectly() public {
        _expectHookRevert(IHooks.beforeInitialize.selector, FlickHook.OnlyThroughCreateVault.selector);
        poolManager.initialize(key, uint160(1 << 96));
    }

    function test_RevertWhen_OutsiderAddsLiquidity() public {
        _createVault(_params());
        // PositionManager wraps the error; search the revert data for our selector.
        try this.mintAsOutsider() {
            fail("mint should have reverted");
        } catch (bytes memory reason) {
            assertTrue(_contains(reason, abi.encodeWithSelector(FlickHook.OnlyVaultLiquidity.selector)));
        }
    }

    /// @dev External so the test can catch the revert.
    function mintAsOutsider() external {
        positionManager.mint(
            key, 700, 840, 1e12, type(uint256).max, type(uint256).max, address(this), block.timestamp, ""
        );
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    // ---------- Swaps and the oracle check ----------

    function test_Swap_Normal_ChargesBaseFee() public {
        _createVault(_params());

        uint256 eurcBefore = eurc.balanceOf(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));

        // Sell 1,000 EURC for USDC.
        uint24 fee = _swap(baseIsToken0);

        assertEq(fee, SWAP_FEE);
        assertEq(eurcBefore - eurc.balanceOf(address(this)), 1000e6);
        // 1,000 EUR at 1.08 is 1,080 USD, less a small fee and price impact.
        assertApproxEqRel(usdc.balanceOf(address(this)) - usdcBefore, 1080e6, 0.002e18);
    }

    /// One second past the limit already stops trading.
    function test_Swap_JustStale_IsHalted() public {
        _createVault(_params());
        vm.warp(block.timestamp + MAX_STALE + 1);

        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, true, key, "", address(this), block.timestamp);
    }

    function test_Swap_AtStalenessLimit_StillTrades() public {
        _createVault(_params());
        vm.warp(block.timestamp + MAX_STALE);
        assertEq(_swap(true), SWAP_FEE);
    }

    function test_Swap_FeedsDiverge_IsHalted() public {
        VaultParams memory params = _params();
        params.secondaryOracle = IFxOracle(address(secondOracle));
        _createVault(params);
        assertEq(_swap(true), SWAP_FEE);

        // Second source moves 2% away. Limit is 1%.
        secondOracle.setPrice(EUR_USD * 102 / 100);
        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, true, key, "", address(this), block.timestamp);

        // Back inside the limit.
        secondOracle.setPrice(EUR_USD * 1005 / 1000);
        assertEq(_swap(true), SWAP_FEE);
    }

    function test_Swap_SecondFeedStale_IsHalted() public {
        VaultParams memory params = _params();
        params.secondaryOracle = IFxOracle(address(secondOracle));
        _createVault(params);

        vm.warp(block.timestamp + MAX_STALE + 1);
        oracle.setPrice(EUR_USD); // primary is fresh, second is not

        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, true, key, "", address(this), block.timestamp);
    }

    function test_Swap_HardStale_BlocksBothDirections() public {
        _createVault(_params());

        // Off-centre first, so one direction would lead back to it.
        _swap(true);

        // Weekend: the feed is now too old to trust.
        vm.warp(block.timestamp + MAX_STALE + 1);

        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, true, key, "", address(this), block.timestamp);

        _expectHookRevert(IHooks.beforeSwap.selector, FlickHook.SwapHalted.selector);
        swapRouter.swapExactTokensForTokens(1000e6, 0, false, key, "", address(this), block.timestamp);
    }

    function test_Swap_HardStale_FreshUpdateReopens() public {
        _createVault(_params());
        vm.warp(block.timestamp + MAX_STALE + 1);

        oracle.setPrice(EUR_USD);
        assertEq(_swap(true), SWAP_FEE);
    }

    function test_HardStale_WithdrawalsStillWork() public {
        uint256 shares = _createVault(_params());
        vm.warp(block.timestamp + MAX_STALE + 1);

        vm.prank(curator);
        (uint256 out0, uint256 out1) = hook.withdraw(key, shares, 0, 0, curator, block.timestamp);
        assertApproxEqRel(out0, SEED, 1e12);
        assertApproxEqRel(out1, SEED, 1e12);
    }

    // ---------- Views ----------

    function test_OracleState_TracksStatus() public {
        _createVault(_params());

        (uint256 price, OracleStatus status, uint24 fee) = hook.oracleState(poolId);
        assertEq(price, EUR_USD);
        assertEq(uint8(status), uint8(OracleStatus.Normal));
        assertEq(fee, SWAP_FEE);

        vm.warp(block.timestamp + MAX_STALE + 1);
        (, status, fee) = hook.oracleState(poolId);
        assertEq(uint8(status), uint8(OracleStatus.Halted));
        assertEq(fee, SWAP_FEE);

        oracle.setPrice(EUR_USD);
        (, status,) = hook.oracleState(poolId);
        assertEq(uint8(status), uint8(OracleStatus.Normal));
    }

    // ---------- Guardian handover ----------

    function test_TransferGuardian_TwoSteps() public {
        address multisig = makeAddr("multisig");
        vm.prank(guardian);
        hook.transferGuardian(multisig);
        assertEq(hook.guardian(), guardian, "unchanged until accepted");
        assertEq(hook.pendingGuardian(), multisig);

        vm.prank(multisig);
        hook.acceptGuardian();
        assertEq(hook.guardian(), multisig);
        assertEq(hook.pendingGuardian(), address(0));

        // The old guardian has lost its powers.
        vm.prank(guardian);
        vm.expectRevert(FlickHook.NotGuardian.selector);
        hook.setOracleApproved(address(oracle), false);
    }

    function test_RevertWhen_StrangerTransfersGuardian() public {
        vm.expectRevert(FlickHook.NotGuardian.selector);
        hook.transferGuardian(address(this));
    }

    function test_RevertWhen_WrongAddressAcceptsGuardian() public {
        vm.prank(guardian);
        hook.transferGuardian(makeAddr("multisig"));
        vm.expectRevert(FlickHook.NotPendingGuardian.selector);
        hook.acceptGuardian();
    }

    function test_RevertWhen_TransferringGuardianToZero() public {
        vm.prank(guardian);
        vm.expectRevert(FlickHook.ZeroAddress.selector);
        hook.transferGuardian(address(0));
    }

    function test_RevertWhen_OracleStateForUnknownPool() public {
        vm.expectRevert(FlickHook.VaultNotFound.selector);
        hook.oracleState(poolId);
    }
}
