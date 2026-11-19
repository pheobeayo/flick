// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFxOracle
/// @notice Read-only FX price source. Price = quote tokens per base token, 18 decimals (1.08e18 = 1.08).
interface IFxOracle {
    /// @return price Quote per base, 18 decimals.
    /// @return updatedAt When the source observed the price.
    function latest() external view returns (uint256 price, uint64 updatedAt);

    /// @notice Pair name, for example "EUR / USD".
    function description() external view returns (string memory);
}
