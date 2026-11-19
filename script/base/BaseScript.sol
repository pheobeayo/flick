// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {Deployers} from "../../test/utils/Deployers.sol";

/// @notice Finds Uniswap v4 on the current chain, or deploys it on a local Anvil chain.
contract BaseScript is Script, Deployers {
    constructor() {
        deployArtifacts();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    function _etch(address target, bytes memory bytecode) internal override {
        if (block.chainid == 31337) {
            vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '",', '"', vm.toString(bytecode), '"]'));
        } else {
            revert("Unsupported etch on this network");
        }
    }
}
