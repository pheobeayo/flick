// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {FlickHook} from "../src/FlickHook.sol";
import {IFxOracle} from "../src/interfaces/IFxOracle.sol";
import {ChainlinkFxOracle, IAggregatorV3} from "../src/oracles/ChainlinkFxOracle.sol";
import {MockFxOracle} from "../src/oracles/MockFxOracle.sol";
import {VaultParams} from "../src/types/FlickTypes.sol";

/// @notice Sets up a price source, then creates and seeds a vault.
/// @dev Env: HOOK, BASE_TOKEN, QUOTE_TOKEN, SEED_BASE, SEED_QUOTE (raw amounts), plus one of
///      ORACLE (already approved), CHAINLINK_FEED (+ optional SEQUENCER_FEED) or MOCK_PRICE (18 decimals).
///      The last two need the sender to be the guardian.
contract CreateVaultScript is BaseScript {
    int24 internal constant TICK_SPACING = 10;

    function run() public {
        FlickHook hook = FlickHook(vm.envAddress("HOOK"));
        address base = vm.envAddress("BASE_TOKEN");
        address quote = vm.envAddress("QUOTE_TOKEN");
        uint256 seedBase = vm.envUint("SEED_BASE");
        uint256 seedQuote = vm.envUint("SEED_QUOTE");

        bool baseIsToken0 = base < quote;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(baseIsToken0 ? base : quote),
            currency1: Currency.wrap(baseIsToken0 ? quote : base),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.startBroadcast();

        IFxOracle oracle = _oracle(hook);

        IERC20(base).approve(address(hook), seedBase);
        IERC20(quote).approve(address(hook), seedQuote);

        (PoolId poolId, uint256 shares) = hook.createVault(
            key, baseIsToken0, _params(oracle), baseIsToken0 ? seedBase : seedQuote, baseIsToken0 ? seedQuote : seedBase
        );

        vm.stopBroadcast();

        console2.log("Oracle:", address(oracle));
        console2.log("Pool id:");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("Curator shares:", shares);
    }

    function _oracle(FlickHook hook) internal returns (IFxOracle oracle) {
        address existing = vm.envOr("ORACLE", address(0));
        if (existing != address(0)) return IFxOracle(existing);

        string memory name = vm.envOr("ORACLE_DESCRIPTION", string("EUR / USD"));
        address feed = vm.envOr("CHAINLINK_FEED", address(0));
        if (feed != address(0)) {
            IAggregatorV3 sequencer = IAggregatorV3(vm.envOr("SEQUENCER_FEED", address(0)));
            oracle = new ChainlinkFxOracle(IAggregatorV3(feed), sequencer, name);
        } else {
            oracle = new MockFxOracle(name, vm.envUint("MOCK_PRICE"));
        }
        hook.setOracleApproved(address(oracle), true);
    }

    /// @dev Default vault settings. The curator can change them later with queueParams.
    function _params(IFxOracle oracle) internal pure returns (VaultParams memory) {
        return VaultParams({
            primaryOracle: oracle,
            secondaryOracle: IFxOracle(address(0)),
            bandHalfWidthBps: 50, // liquidity sits within 0.5% of the oracle price
            recenterThresholdBps: 1, // recenter on any move of 0.01% or more
            maxDivergenceBps: 100,
            feePips: 500, // 0.05% swap fee: prices out most front-running of a Chainlink update
            performanceFeeBps: 1000, // curator keeps 10% of swap fees
            maxStalenessSeconds: 25 hours // just over Chainlink's daily heartbeat; swaps stop after this
        });
    }
}
