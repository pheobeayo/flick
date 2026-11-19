// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {FlickHook} from "../src/FlickHook.sol";

/// @notice Mines a valid hook address and deploys FlickHook. Env: GUARDIAN.
contract DeployHookScript is BaseScript {
    function run() public {
        address guardian = vm.envAddress("GUARDIAN");

        // Must match getHookPermissions().
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(poolManager, guardian);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(FlickHook).creationCode, constructorArgs);

        vm.startBroadcast();
        FlickHook hook = new FlickHook{salt: salt}(poolManager, guardian);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
        console2.log("FlickHook:", address(hook));
        console2.log("Guardian:", guardian);
    }
}
