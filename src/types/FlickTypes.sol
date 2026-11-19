// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFxOracle} from "../interfaces/IFxOracle.sol";

/// @notice How an FX pair maps onto a pool. Base is the priced currency (EURC), quote is USDC.
struct Pair {
    uint8 baseDecimals;
    uint8 quoteDecimals;
    bool baseIsToken0;
}

/// @notice Normal: price trusted, swaps run. Halted: feed stale, revoked or disputed; swaps stop.
enum OracleStatus {
    Normal,
    Halted
}

/// @notice Curator settings for a vault.
struct VaultParams {
    IFxOracle primaryOracle;
    IFxOracle secondaryOracle;
    uint16 bandHalfWidthBps;
    uint16 recenterThresholdBps;
    uint16 maxDivergenceBps;
    uint24 feePips;
    uint16 performanceFeeBps;
    uint64 maxStalenessSeconds;
}

/// @notice Everything the hook stores for one pool.
struct Vault {
    address curator;
    Pair pair;
    VaultParams params;
    uint256 centrePrice;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 idle0;
    uint256 idle1;
    uint256 totalShares;
    uint256 curatorFees0;
    uint256 curatorFees1;
    bool paused;
}

/// @notice A queued settings change.
struct PendingParams {
    VaultParams params;
    uint64 readyAt;
}
