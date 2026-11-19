// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {FlickHook} from "../src/FlickHook.sol";
import {OracleStatus} from "../src/types/FlickTypes.sol";

/// @notice Swaps through a vault and prints what the hook did.
/// @dev Env: HOOK, BASE_TOKEN, QUOTE_TOKEN, AMOUNT_IN (raw), SELL_BASE (true sells EURC).
contract SwapScript is BaseScript {
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_SPACING = 10;

    function run() public {
        FlickHook hook = FlickHook(vm.envAddress("HOOK"));
        address base = vm.envAddress("BASE_TOKEN");
        address quote = vm.envAddress("QUOTE_TOKEN");
        uint256 amountIn = vm.envUint("AMOUNT_IN");
        bool sellBase = vm.envBool("SELL_BASE");

        bool baseIsToken0 = base < quote;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(baseIsToken0 ? base : quote),
            currency1: Currency.wrap(baseIsToken0 ? quote : base),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = key.toId();

        (uint256 price, OracleStatus status, uint24 feePips) = hook.oracleState(poolId);
        console2.log("Oracle price (18 decimals):", price);
        console2.log("Status (0 normal, 1 halted):", uint8(status));
        console2.log("Swap fee (pips, 100 = 0.01%):", feePips);
        console2.log("Vault centre before:", hook.getVault(poolId).centrePrice);

        IERC20 tokenIn = IERC20(sellBase ? base : quote);
        IERC20 tokenOut = IERC20(sellBase ? quote : base);

        vm.startBroadcast();
        uint256 outBefore = tokenOut.balanceOf(msg.sender);
        tokenIn.approve(address(swapRouter), amountIn);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: sellBase == baseIsToken0,
            poolKey: key,
            hookData: "",
            receiver: msg.sender,
            deadline: block.timestamp + 300
        });
        vm.stopBroadcast();

        console2.log("Sold (raw):", amountIn);
        console2.log("Received (raw):", tokenOut.balanceOf(msg.sender) - outBefore);
        console2.log("Vault centre after:", hook.getVault(poolId).centrePrice);
    }
}
