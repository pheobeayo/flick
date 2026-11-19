// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockFxOracle} from "../../src/oracles/MockFxOracle.sol";

contract MockFxOracleTest is Test {
    MockFxOracle internal oracle;
    address internal stranger = makeAddr("stranger");

    uint256 internal constant EUR_USD = 1.08e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new MockFxOracle("EUR / USD", EUR_USD);
    }

    function test_InitialState() public view {
        (uint256 price, uint64 updatedAt) = oracle.latest();
        assertEq(price, EUR_USD);
        assertEq(updatedAt, block.timestamp);
        assertEq(oracle.description(), "EUR / USD");
    }

    function test_SetPrice_MovesRateAndTimestamp() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 moved = (EUR_USD * 101) / 100; // EUR up 1%
        oracle.setPrice(moved);

        (uint256 price, uint64 updatedAt) = oracle.latest();
        assertEq(price, moved);
        assertEq(updatedAt, block.timestamp);
    }

    function test_SetPriceAt_SimulatesStaleFeed() public {
        vm.warp(block.timestamp + 3 days); // weekend passes
        uint64 friday = uint64(block.timestamp - 2 days);
        oracle.setPriceAt(EUR_USD, friday);

        (, uint64 updatedAt) = oracle.latest();
        assertEq(block.timestamp - updatedAt, 2 days);
    }

    function test_NgnScalePriceFits() public {
        oracle.setPrice(6.8e14); // 1 cNGN = 0.00068 USDC
        (uint256 price,) = oracle.latest();
        assertEq(price, 6.8e14);
    }

    function test_RevertWhen_StrangerSetsPrice() public {
        vm.prank(stranger);
        vm.expectRevert(MockFxOracle.NotOwner.selector);
        oracle.setPrice(1e18);
    }

    function test_RevertWhen_ZeroPrice() public {
        vm.expectRevert(MockFxOracle.ZeroPrice.selector);
        oracle.setPrice(0);
    }

    function test_RevertWhen_FutureTimestamp() public {
        vm.expectRevert(MockFxOracle.FutureTimestamp.selector);
        oracle.setPriceAt(1e18, uint64(block.timestamp + 1));
    }

    function testFuzz_SetPrice(uint256 price) public {
        vm.assume(price != 0);
        oracle.setPrice(price);
        (uint256 stored,) = oracle.latest();
        assertEq(stored, price);
    }
}
