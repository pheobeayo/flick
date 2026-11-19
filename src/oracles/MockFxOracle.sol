// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFxOracle} from "../interfaces/IFxOracle.sol";

/// @title MockFxOracle
/// @notice Hand-set FX price for tests and the demo. Never approve one on mainnet.
contract MockFxOracle is IFxOracle {
    error NotOwner();
    error ZeroPrice();
    error FutureTimestamp();

    event PriceSet(uint256 price, uint64 updatedAt);

    address public immutable owner;

    string private _description;
    uint256 private _price;
    uint64 private _updatedAt;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(string memory description_, uint256 initialPrice) {
        owner = msg.sender;
        _description = description_;
        _set(initialPrice, uint64(block.timestamp));
    }

    function latest() external view returns (uint256 price, uint64 updatedAt) {
        return (_price, _updatedAt);
    }

    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice Set the rate as observed now.
    function setPrice(uint256 price) external onlyOwner {
        _set(price, uint64(block.timestamp));
    }

    /// @notice Set the rate as observed at a past time, to simulate a stale feed.
    function setPriceAt(uint256 price, uint64 updatedAt) external onlyOwner {
        if (updatedAt > block.timestamp) revert FutureTimestamp();
        _set(price, updatedAt);
    }

    function _set(uint256 price, uint64 updatedAt) private {
        if (price == 0) revert ZeroPrice();
        _price = price;
        _updatedAt = updatedAt;
        emit PriceSet(price, updatedAt);
    }
}
