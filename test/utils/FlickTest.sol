// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BaseTest} from "./BaseTest.sol";

import {FlickHook} from "../../src/FlickHook.sol";
import {IFxOracle} from "../../src/interfaces/IFxOracle.sol";
import {MockFxOracle} from "../../src/oracles/MockFxOracle.sol";
import {FxMath} from "../../src/libraries/FxMath.sol";
import {Vault, VaultParams} from "../../src/types/FlickTypes.sol";

/// @dev Shared setup: EURC/USDC (6 decimals each), two mock EUR/USD feeds, the hook, helpers.
abstract contract FlickTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant EUR_USD = 1.08e18;
    int24 internal constant TICK_SPACING = 10;
    uint24 internal constant SWAP_FEE = 100; // 0.01%
    uint64 internal constant MAX_STALE = 1 hours;

    /// Curator's seed: 1,000,000 of each token.
    uint256 internal constant SEED = 1_000_000e6;

    address internal guardian = makeAddr("guardian");
    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockERC20 internal eurc;
    MockERC20 internal usdc;
    MockFxOracle internal oracle;
    MockFxOracle internal secondOracle;

    FlickHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;
    bool internal baseIsToken0;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        deployArtifactsAndLabel();

        eurc = new MockERC20("EURC", "EURC", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        baseIsToken0 = address(eurc) < address(usdc);

        oracle = new MockFxOracle("EUR / USD", EUR_USD);
        secondOracle = new MockFxOracle("EUR / USD (second source)", EUR_USD);

        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG)
                ^ (0x4444 << 144)
        );
        deployCodeTo("FlickHook.sol:FlickHook", abi.encode(poolManager, guardian), hookAddress);
        hook = FlickHook(hookAddress);

        vm.startPrank(guardian);
        hook.setOracleApproved(address(oracle), true);
        hook.setOracleApproved(address(secondOracle), true);
        vm.stopPrank();

        key = _key(TICK_SPACING);
        poolId = key.toId();

        _fund(address(this));
        _fund(curator);
        _fund(alice);
        _fund(bob);
    }

    // ---------- Helpers ----------

    /// Funds `who` and approves the hook, router and Permit2.
    function _fund(address who) internal {
        eurc.mint(who, 1_000_000_000e6);
        usdc.mint(who, 1_000_000_000e6);
        vm.startPrank(who);
        eurc.approve(address(hook), type(uint256).max);
        usdc.approve(address(hook), type(uint256).max);
        eurc.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        eurc.approve(address(permit2), type(uint256).max);
        usdc.approve(address(permit2), type(uint256).max);
        permit2.approve(address(eurc), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _key(int24 tickSpacing) internal view returns (PoolKey memory) {
        (address token0, address token1) =
            baseIsToken0 ? (address(eurc), address(usdc)) : (address(usdc), address(eurc));
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
    }

    function _params() internal view returns (VaultParams memory) {
        return VaultParams({
            primaryOracle: IFxOracle(address(oracle)),
            secondaryOracle: IFxOracle(address(0)),
            bandHalfWidthBps: 50,
            recenterThresholdBps: 25,
            maxDivergenceBps: 100,
            feePips: SWAP_FEE,
            performanceFeeBps: 0,
            maxStalenessSeconds: MAX_STALE
        });
    }

    /// Curator creates the vault and seeds it with SEED of each token.
    function _createVault(VaultParams memory params) internal returns (uint256 shares) {
        vm.prank(curator);
        (, shares) = hook.createVault(key, baseIsToken0, params, SEED, SEED);
    }

    /// Swaps as `who` and returns the fee charged, from the Swap event.
    function _swapAs(address who, bool zeroForOne, uint256 amountIn) internal returns (uint24 fee) {
        vm.recordLogs();
        vm.prank(who);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: "",
            receiver: who,
            deadline: block.timestamp
        });

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event");
    }

    /// Swaps 1,000 units as the test contract.
    function _swap(bool zeroForOne) internal returns (uint24 fee) {
        return _swapAs(address(this), zeroForOne, 1000e6);
    }

    function _expectHookRevert(bytes4 hookSelector, bytes4 reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookSelector,
                abi.encodeWithSelector(reason),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// Value of a token pair in USDC units at an oracle price.
    function _valueAt(uint256 price, uint256 amount0, uint256 amount1) internal view returns (uint256) {
        Vault memory vault = hook.getVault(poolId);
        (uint256 base, uint256 quote) = baseIsToken0 ? (amount0, amount1) : (amount1, amount0);
        return quote + FxMath.quoteValue(base, price, vault.pair);
    }

    /// Value of everything `who` holds in tokens, in USDC units at EUR_USD.
    function _walletValue(address who) internal view returns (uint256) {
        return usdc.balanceOf(who) + eurc.balanceOf(who) * EUR_USD / 1e18;
    }
}
