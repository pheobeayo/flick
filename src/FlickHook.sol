// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IFxOracle} from "./interfaces/IFxOracle.sol";
import {FxMath} from "./libraries/FxMath.sol";
import {BandMath} from "./libraries/BandMath.sol";
import {Pair, Vault, VaultParams, PendingParams, OracleStatus} from "./types/FlickTypes.sol";

/// @title FlickHook
/// @notice Curated FX liquidity vaults for Uniswap v4.
/// @dev Before every swap, if the oracle rate has moved, the vault's liquidity is
///      moved to the new rate first, so nobody trades against a stale price.
///      One hook serves many vaults, keyed by PoolId.
contract FlickHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    error NotGuardian();
    error ZeroAddress();
    error OracleNotApproved(address oracle);
    error OracleNotFresh();
    error ZeroOraclePrice();
    error WrongHook();
    error FeeNotDynamic();
    error NativeCurrencyNotSupported();
    error VaultAlreadyExists();
    error VaultNotFound();
    error InvalidParams();
    error OnlyThroughCreateVault();
    error OnlyVaultLiquidity();
    error SwapHalted();
    error SeedTooSmall();
    error ZeroShares();
    error InsufficientShares();
    error SlippageExceeded();
    error NotCurator();
    error VaultPaused();
    error RecenterNotNeeded();
    error ParamsNotReady();
    error OracleSwitchTooFar();
    error DeadlinePassed();
    error NotPendingGuardian();

    event OracleApprovalSet(address indexed oracle, bool approved);
    event GuardianTransferStarted(address indexed currentGuardian, address indexed pendingGuardian);
    event GuardianTransferred(address indexed previousGuardian, address indexed newGuardian);
    event VaultCreated(
        PoolId indexed poolId,
        address indexed curator,
        address primaryOracle,
        address secondaryOracle,
        bool baseIsToken0,
        uint256 centrePrice
    );

    event Deposited(
        PoolId indexed poolId,
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );
    event Withdrawn(
        PoolId indexed poolId,
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );
    event FeesCollected(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event Recentered(PoolId indexed poolId, uint256 centrePrice, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event ParamsQueued(PoolId indexed poolId, uint64 readyAt);
    event ParamsApplied(PoolId indexed poolId);
    event PausedSet(PoolId indexed poolId, bool paused);
    event CuratorFeesClaimed(PoolId indexed poolId, address indexed to, uint256 amount0, uint256 amount1);

    uint256 public constant MINIMUM_SHARES = 1e12; // locked at creation so supply never hits zero
    uint256 internal constant SHARE_UNIT = 1e18; // one share starts at one quote token
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Protocol limits on curator settings.
    uint16 public constant MAX_BAND_HALF_WIDTH_BPS = 2000; // 20%
    uint24 public constant MAX_FEE_PIPS = 10_000; // 1%
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 2000; // 20% of swap fees
    uint64 public constant MAX_STALENESS_SECONDS = 7 days;

    uint64 public constant PARAMS_DELAY_SECONDS = 1 days; // lets depositors leave first
    uint16 public constant MAX_ORACLE_SWITCH_BPS = 500; // 5%: blocks switching to another currency's feed

    enum Action {
        Seed,
        Deposit,
        Withdraw,
        Recenter
    }

    /// @notice Approves and revokes oracles, pauses vaults. Cannot move funds. Should be a multisig.
    address public guardian;
    address public pendingGuardian;

    mapping(address oracle => bool approved) public approvedOracles;

    mapping(PoolId poolId => Vault vault) private _vaults;

    mapping(PoolId poolId => mapping(address account => uint256 shares)) private _shares;

    mapping(PoolId poolId => PendingParams pending) private _pendingParams;

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    modifier onlyCurator(PoolId poolId) {
        if (msg.sender != _vaults[poolId].curator) revert NotCurator();
        _;
    }

    constructor(IPoolManager poolManager_, address guardian_) BaseHook(poolManager_) {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
    }

    // ---------- Guardian ----------

    /// @notice Revoking an oracle halts every vault that uses it.
    function setOracleApproved(address oracle, bool approved) external onlyGuardian {
        if (oracle == address(0)) revert ZeroAddress();
        approvedOracles[oracle] = approved;
        emit OracleApprovalSet(oracle, approved);
    }

    /// @notice Step 1 of handing over the role. The new guardian must call `acceptGuardian`.
    function transferGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert ZeroAddress();
        pendingGuardian = newGuardian;
        emit GuardianTransferStarted(guardian, newGuardian);
    }

    function acceptGuardian() external {
        if (msg.sender != pendingGuardian) revert NotPendingGuardian();
        emit GuardianTransferred(guardian, msg.sender);
        guardian = msg.sender;
        pendingGuardian = address(0);
    }

    /// @notice Stops swaps and deposits for one vault. Withdrawals always work.
    function setPaused(PoolId poolId, bool paused) external onlyGuardian {
        if (_vaults[poolId].curator == address(0)) revert VaultNotFound();
        _vaults[poolId].paused = paused;
        emit PausedSet(poolId, paused);
    }

    // ---------- Curator ----------

    /// @notice Queue new settings. Applicable after `PARAMS_DELAY_SECONDS`; re-queuing restarts the wait.
    function queueParams(PoolId poolId, VaultParams calldata params) external onlyCurator(poolId) {
        _validateParams(params);
        uint64 readyAt = uint64(block.timestamp) + PARAMS_DELAY_SECONDS;
        _pendingParams[poolId] = PendingParams({params: params, readyAt: readyAt});
        emit ParamsQueued(poolId, readyAt);
    }

    /// @notice Apply queued settings after the wait. Anyone can call.
    function applyParams(PoolId poolId) external {
        PendingParams storage pending = _pendingParams[poolId];
        if (pending.readyAt == 0 || block.timestamp < pending.readyAt) revert ParamsNotReady();
        // Approval may have been revoked during the wait.
        _requireApproved(pending.params.primaryOracle);
        if (address(pending.params.secondaryOracle) != address(0)) _requireApproved(pending.params.secondaryOracle);

        Vault storage vault = _vaults[poolId];
        // A new primary feed must price the same pair.
        if (pending.params.primaryOracle != vault.params.primaryOracle) {
            (uint256 price,) = pending.params.primaryOracle.latest();
            if (price == 0) revert ZeroOraclePrice();
            if (BandMath.deviationBps(price, vault.centrePrice) > MAX_ORACLE_SWITCH_BPS) revert OracleSwitchTooFar();
        }

        vault.params = pending.params;
        delete _pendingParams[poolId];
        emit ParamsApplied(poolId);
    }

    function claimCuratorFees(PoolKey calldata key, address to) external returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        Vault storage vault = _vaults[poolId];
        if (msg.sender != vault.curator) revert NotCurator();
        if (to == address(0)) revert ZeroAddress();

        (amount0, amount1) = (vault.curatorFees0, vault.curatorFees1);
        vault.curatorFees0 = 0;
        vault.curatorFees1 = 0;
        if (amount0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransfer(to, amount0);
        if (amount1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(to, amount1);
        emit CuratorFeesClaimed(poolId, to, amount0, amount1);
    }

    // ---------- Vault creation ----------

    /// @notice Create and seed a pool and its vault. The caller becomes the curator.
    /// @dev The pool opens at the oracle price with the seed as liquidity, in one transaction.
    function createVault(
        PoolKey calldata key,
        bool baseIsToken0,
        VaultParams calldata params,
        uint256 amount0,
        uint256 amount1
    ) external returns (PoolId poolId, uint256 shares) {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert FeeNotDynamic();
        if (key.currency0.isAddressZero()) revert NativeCurrencyNotSupported();

        poolId = key.toId();
        if (_vaults[poolId].curator != address(0)) revert VaultAlreadyExists();
        _validateParams(params);

        // Pull tokens before minting shares.
        IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), amount1);
        if (_vaults[poolId].curator != address(0)) revert VaultAlreadyExists();

        uint256 price = _configureVault(poolId, key, baseIsToken0, params);
        shares = _mintSeedShares(poolId, price, amount0, amount1);

        // The hook's own calls skip its callbacks, so this passes `_beforeInitialize`.
        poolManager.initialize(key, FxMath.sqrtPriceX96FromPrice(price, _vaults[poolId].pair));
        poolManager.unlock(abi.encode(Action.Seed, key, address(0), uint256(0)));
    }

    function _configureVault(PoolId poolId, PoolKey calldata key, bool baseIsToken0, VaultParams calldata params)
        internal
        returns (uint256 price)
    {
        Vault storage vault = _vaults[poolId];

        uint8 decimals0 = IERC20Metadata(Currency.unwrap(key.currency0)).decimals();
        uint8 decimals1 = IERC20Metadata(Currency.unwrap(key.currency1)).decimals();
        Pair memory pair = Pair({
            baseDecimals: baseIsToken0 ? decimals0 : decimals1,
            quoteDecimals: baseIsToken0 ? decimals1 : decimals0,
            baseIsToken0: baseIsToken0
        });

        vault.curator = msg.sender;
        vault.pair = pair;
        vault.params = params;

        OracleStatus status;
        (price, status) = _oracleState(vault);
        if (status != OracleStatus.Normal) revert OracleNotFresh();
        vault.centrePrice = price;
        (vault.tickLower, vault.tickUpper) = BandMath.bandTicks(price, params.bandHalfWidthBps, key.tickSpacing, pair);

        emit VaultCreated(
            poolId, msg.sender, address(params.primaryOracle), address(params.secondaryOracle), baseIsToken0, price
        );
    }

    /// @dev Seed valued at the oracle price.
    function _mintSeedShares(PoolId poolId, uint256 price, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 shares)
    {
        Vault storage vault = _vaults[poolId];
        uint256 totalShares =
            _quoteValue(vault.pair, price, amount0, amount1) * SHARE_UNIT / (10 ** vault.pair.quoteDecimals);
        if (totalShares <= MINIMUM_SHARES) revert SeedTooSmall();

        shares = totalShares - MINIMUM_SHARES;
        vault.totalShares = totalShares;
        _shares[poolId][DEAD] = MINIMUM_SHARES;
        _shares[poolId][msg.sender] = shares;
        vault.idle0 = amount0;
        vault.idle1 = amount1;

        emit Deposited(poolId, msg.sender, msg.sender, shares, amount0, amount1);
    }

    // ---------- Deposits and withdrawals ----------

    /// @notice Mint `shares` by paying the same fraction of everything the vault holds, rounded up.
    /// @dev Uses no price, so it cannot trade against a stale oracle. Size the maxes with `previewDeposit`.
    function deposit(
        PoolKey calldata key,
        uint256 shares,
        uint256 amount0Max,
        uint256 amount1Max,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (shares == 0) revert ZeroShares();
        if (to == address(0)) revert ZeroAddress();
        PoolId poolId = key.toId();
        if (_vaults[poolId].curator == address(0)) revert VaultNotFound();
        if (_vaults[poolId].paused) revert VaultPaused();

        (amount0, amount1) =
            abi.decode(poolManager.unlock(abi.encode(Action.Deposit, key, msg.sender, shares)), (uint256, uint256));
        if (amount0 > amount0Max || amount1 > amount1Max) revert SlippageExceeded();

        _vaults[poolId].totalShares += shares;
        _shares[poolId][to] += shares;
        emit Deposited(poolId, msg.sender, to, shares, amount0, amount1);
    }

    /// @notice Burn `shares` for the same fraction of everything the vault holds, rounded down.
    /// @dev Reads no oracle and ignores pause, so depositors can always leave.
    function withdraw(
        PoolKey calldata key,
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (shares == 0) revert ZeroShares();
        if (to == address(0)) revert ZeroAddress();
        PoolId poolId = key.toId();
        if (_shares[poolId][msg.sender] < shares) revert InsufficientShares();

        // Total supply drops inside the callback, after the fraction is computed.
        _shares[poolId][msg.sender] -= shares;

        (amount0, amount1) =
            abi.decode(poolManager.unlock(abi.encode(Action.Withdraw, key, to, shares)), (uint256, uint256));
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        emit Withdrawn(poolId, msg.sender, to, shares, amount0, amount1);
    }

    /// @notice Recenter now instead of waiting for a swap. Anyone can call.
    function recenter(PoolKey calldata key) external {
        Vault storage vault = _vaults[key.toId()];
        if (vault.curator == address(0)) revert VaultNotFound();
        if (vault.paused) revert VaultPaused();
        poolManager.unlock(abi.encode(Action.Recenter, key, address(0), uint256(0)));
    }

    /// @dev Only one unlock can be open at a time, which also blocks re-entry.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, PoolKey memory key, address account, uint256 shares) =
            abi.decode(data, (Action, PoolKey, address, uint256));
        Vault storage vault = _vaults[key.toId()];

        if (action == Action.Seed) {
            _deployIdle(key, vault);
            return "";
        }
        if (action == Action.Recenter) {
            (uint256 price, OracleStatus status) = _oracleState(vault);
            if (status != OracleStatus.Normal || !_needsRecenter(vault, price)) revert RecenterNotNeeded();
            _recenter(key, vault, price);
            return "";
        }

        _collectFees(key, vault);
        (uint256 amount0, uint256 amount1) =
            action == Action.Deposit ? _deposit(key, vault, account, shares) : _withdraw(key, vault, account, shares);
        return abi.encode(amount0, amount1);
    }

    // ---------- Views ----------

    function getVault(PoolId poolId) external view returns (Vault memory) {
        return _vaults[poolId];
    }

    function getPendingParams(PoolId poolId) external view returns (PendingParams memory) {
        return _pendingParams[poolId];
    }

    function sharesOf(PoolId poolId, address account) external view returns (uint256) {
        return _shares[poolId][account];
    }

    /// @notice Pool position plus idle tokens. Excludes uncollected fees.
    function totalAssets(PoolId poolId) public view returns (uint256 amount0, uint256 amount1) {
        Vault storage vault = _vaults[poolId];
        if (vault.curator == address(0)) revert VaultNotFound();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        (amount0, amount1) = _positionAmounts(sqrtPriceX96, vault.tickLower, vault.tickUpper, vault.liquidity, false);
        amount0 += vault.idle0;
        amount1 += vault.idle1;
    }

    /// @notice Estimated cost of minting `shares`. Add a small margin; fees are collected at deposit.
    function previewDeposit(PoolId poolId, uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        Vault storage vault = _vaults[poolId];
        if (vault.curator == address(0)) revert VaultNotFound();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = FullMath.mulDivRoundingUp(vault.liquidity, shares, vault.totalShares).toUint128();
        (amount0, amount1) = _positionAmounts(sqrtPriceX96, vault.tickLower, vault.tickUpper, liquidity, true);
        amount0 += FullMath.mulDivRoundingUp(vault.idle0, shares, vault.totalShares);
        amount1 += FullMath.mulDivRoundingUp(vault.idle1, shares, vault.totalShares);
    }

    /// @notice What a swap would see right now.
    function oracleState(PoolId poolId) external view returns (uint256 price, OracleStatus status, uint24 feePips) {
        Vault storage vault = _vaults[poolId];
        if (vault.curator == address(0)) revert VaultNotFound();
        (price, status) = _oracleState(vault);
        feePips = vault.params.feePips;
    }

    // ---------- Hook callbacks ----------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev v4 skips this for the hook's own calls, so reaching it means an outsider.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert OnlyThroughCreateVault();
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert OnlyVaultLiquidity();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Vault storage vault = _vaults[poolId];
        if (vault.paused) revert VaultPaused();
        (uint256 price, OracleStatus status) = _oracleState(vault);

        if (status != OracleStatus.Normal) revert SwapHalted();
        // Move liquidity to the new rate before this swap trades.
        if (_needsRecenter(vault, price)) _recenter(key, vault, price);

        uint24 fee = vault.params.feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    // ---------- Internal ----------

    function _needsRecenter(Vault storage vault, uint256 price) internal view returns (bool) {
        return BandMath.needsRecenter(price, vault.centrePrice, vault.params.recenterThresholdBps);
    }

    /// @dev Remove all liquidity (the pool is now empty), move the empty pool to `price` for free,
    ///      re-add liquidity around it. What does not fit the new band stays idle.
    function _recenter(PoolKey memory key, Vault storage vault, uint256 price) internal {
        PoolId poolId = key.toId();
        BalanceDelta net = BalanceDeltaLibrary.ZERO_DELTA;

        if (vault.liquidity != 0) {
            (BalanceDelta removed, BalanceDelta fees) =
                poolManager.modifyLiquidity(key, _liquidityParams(vault, -int256(uint256(vault.liquidity))), "");
            vault.liquidity = 0;
            net = removed;
            // `removed` includes fees; book it all as idle, then take the curator's cut.
            vault.idle0 += _positive(removed.amount0());
            vault.idle1 += _positive(removed.amount1());
            _bookFees(poolId, vault, _positive(fees.amount0()), _positive(fees.amount1()), true);
        }

        uint160 target = FxMath.sqrtPriceX96FromPrice(price, vault.pair);
        (uint160 current,,,) = poolManager.getSlot0(poolId);
        if (current != target) {
            net = net
                + poolManager.swap(
                    key, SwapParams({zeroForOne: target < current, amountSpecified: -1, sqrtPriceLimitX96: target}), ""
                );
        }

        vault.centrePrice = price;
        (vault.tickLower, vault.tickUpper) =
            BandMath.bandTicks(price, vault.params.bandHalfWidthBps, key.tickSpacing, vault.pair);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            target,
            TickMath.getSqrtPriceAtTick(vault.tickLower),
            TickMath.getSqrtPriceAtTick(vault.tickUpper),
            vault.idle0,
            vault.idle1
        );
        if (liquidity != 0) {
            (BalanceDelta added,) =
                poolManager.modifyLiquidity(key, _liquidityParams(vault, int256(uint256(liquidity))), "");
            vault.liquidity = liquidity;
            net = net + added;
            vault.idle0 -= _positive(-added.amount0());
            vault.idle1 -= _positive(-added.amount1());
        }

        // Settle the net delta once.
        _take(key.currency0, address(this), net.amount0());
        _take(key.currency1, address(this), net.amount1());
        _pay(key.currency0, address(this), net.amount0());
        _pay(key.currency1, address(this), net.amount1());

        emit Recentered(poolId, price, vault.tickLower, vault.tickUpper, liquidity);
    }

    /// @dev Collect earned fees into idle before any shares are minted or burned.
    function _collectFees(PoolKey memory key, Vault storage vault) internal {
        if (vault.liquidity == 0) return;
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, _liquidityParams(vault, 0), "");
        uint256 fees0 = _take(key.currency0, address(this), delta.amount0());
        uint256 fees1 = _take(key.currency1, address(this), delta.amount1());
        _bookFees(key.toId(), vault, fees0, fees1, false);
    }

    /// @dev Splits fees between vault and curator. `alreadyIdle`: fees already added to idle.
    function _bookFees(PoolId poolId, Vault storage vault, uint256 fees0, uint256 fees1, bool alreadyIdle) internal {
        if (fees0 == 0 && fees1 == 0) return;
        uint256 cut0 = fees0 * vault.params.performanceFeeBps / BandMath.BPS;
        uint256 cut1 = fees1 * vault.params.performanceFeeBps / BandMath.BPS;
        vault.curatorFees0 += cut0;
        vault.curatorFees1 += cut1;
        if (alreadyIdle) {
            vault.idle0 -= cut0;
            vault.idle1 -= cut1;
        } else {
            vault.idle0 += fees0 - cut0;
            vault.idle1 += fees1 - cut1;
        }
        emit FeesCollected(poolId, fees0, fees1);
    }

    function _positive(int128 value) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return value > 0 ? uint256(uint128(value)) : 0;
    }

    function _deployIdle(PoolKey memory key, Vault storage vault) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(vault.tickLower),
            TickMath.getSqrtPriceAtTick(vault.tickUpper),
            vault.idle0,
            vault.idle1
        );
        if (liquidity == 0) return;

        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(key, _liquidityParams(vault, int256(uint256(liquidity))), "");
        vault.liquidity += liquidity;
        vault.idle0 -= _pay(key.currency0, address(this), delta.amount0());
        vault.idle1 -= _pay(key.currency1, address(this), delta.amount1());
    }

    function _deposit(PoolKey memory key, Vault storage vault, address payer, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 totalShares = vault.totalShares;
        uint128 liquidity = FullMath.mulDivRoundingUp(vault.liquidity, shares, totalShares).toUint128();
        uint256 idle0 = FullMath.mulDivRoundingUp(vault.idle0, shares, totalShares);
        uint256 idle1 = FullMath.mulDivRoundingUp(vault.idle1, shares, totalShares);

        vault.idle0 += idle0;
        vault.idle1 += idle1;

        if (liquidity != 0) {
            vault.liquidity += liquidity;
            (BalanceDelta delta,) =
                poolManager.modifyLiquidity(key, _liquidityParams(vault, int256(uint256(liquidity))), "");
            amount0 = _pay(key.currency0, payer, delta.amount0());
            amount1 = _pay(key.currency1, payer, delta.amount1());
        }

        if (idle0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(payer, address(this), idle0);
        if (idle1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(payer, address(this), idle1);
        amount0 += idle0;
        amount1 += idle1;
    }

    function _withdraw(PoolKey memory key, Vault storage vault, address to, uint256 shares)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 totalShares = vault.totalShares;
        uint128 liquidity = FullMath.mulDiv(vault.liquidity, shares, totalShares).toUint128();
        uint256 idle0 = FullMath.mulDiv(vault.idle0, shares, totalShares);
        uint256 idle1 = FullMath.mulDiv(vault.idle1, shares, totalShares);

        vault.totalShares = totalShares - shares;
        vault.idle0 -= idle0;
        vault.idle1 -= idle1;

        if (liquidity != 0) {
            vault.liquidity -= liquidity;
            (BalanceDelta delta,) =
                poolManager.modifyLiquidity(key, _liquidityParams(vault, -int256(uint256(liquidity))), "");
            amount0 = _take(key.currency0, to, delta.amount0());
            amount1 = _take(key.currency1, to, delta.amount1());
        }

        if (idle0 != 0) IERC20(Currency.unwrap(key.currency0)).safeTransfer(to, idle0);
        if (idle1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(to, idle1);
        amount0 += idle0;
        amount1 += idle1;
    }

    function _liquidityParams(Vault storage vault, int256 liquidityDelta)
        internal
        view
        returns (ModifyLiquidityParams memory)
    {
        return ModifyLiquidityParams({
            tickLower: vault.tickLower, tickUpper: vault.tickUpper, liquidityDelta: liquidityDelta, salt: 0
        });
    }

    /// @dev Pays a negative pool delta.
    function _pay(Currency currency, address payer, int128 owed) internal returns (uint256 amount) {
        if (owed >= 0) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = uint256(uint128(-owed));
        poolManager.sync(currency);
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (payer == address(this)) token.safeTransfer(address(poolManager), amount);
        else token.safeTransferFrom(payer, address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev Takes a positive pool delta.
    function _take(Currency currency, address to, int128 owed) internal returns (uint256 amount) {
        if (owed <= 0) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        amount = uint256(uint128(owed));
        poolManager.take(currency, to, amount);
    }

    function _positionAmounts(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        }
    }

    function _quoteValue(Pair memory pair, uint256 price, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint256)
    {
        (uint256 baseAmount, uint256 quoteAmount) = pair.baseIsToken0 ? (amount0, amount1) : (amount1, amount0);
        return quoteAmount + FxMath.quoteValue(baseAmount, price, pair);
    }

    /// @dev Anything short of a fresh, approved, confirmed price halts the vault.
    function _oracleState(Vault storage vault) internal view returns (uint256 price, OracleStatus status) {
        VaultParams storage params = vault.params;

        uint64 updatedAt;
        (price, updatedAt) = params.primaryOracle.latest();
        if (price == 0) revert ZeroOraclePrice();

        if (!approvedOracles[address(params.primaryOracle)]) return (price, OracleStatus.Halted);

        if (_age(updatedAt) > params.maxStalenessSeconds) return (price, OracleStatus.Halted);

        if (address(params.secondaryOracle) != address(0)) {
            (uint256 secondPrice, uint64 secondUpdatedAt) = params.secondaryOracle.latest();
            if (
                secondPrice == 0 || _age(secondUpdatedAt) > params.maxStalenessSeconds
                    || !approvedOracles[address(params.secondaryOracle)]
            ) {
                return (price, OracleStatus.Halted);
            }
            if (BandMath.deviationBps(secondPrice, price) > params.maxDivergenceBps) {
                return (price, OracleStatus.Halted);
            }
        }

        return (price, OracleStatus.Normal);
    }

    function _age(uint64 updatedAt) internal view returns (uint256) {
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    function _requireApproved(IFxOracle oracle) internal view {
        if (!approvedOracles[address(oracle)]) revert OracleNotApproved(address(oracle));
    }

    function _validateParams(VaultParams calldata params) internal view {
        _requireApproved(params.primaryOracle);

        bool hasSecondary = address(params.secondaryOracle) != address(0);
        if (hasSecondary) {
            _requireApproved(params.secondaryOracle);
            if (params.secondaryOracle == params.primaryOracle) revert InvalidParams();
            if (params.maxDivergenceBps == 0) revert InvalidParams();
        }

        if (params.bandHalfWidthBps == 0 || params.bandHalfWidthBps > MAX_BAND_HALF_WIDTH_BPS) revert InvalidParams();
        if (params.recenterThresholdBps == 0 || params.recenterThresholdBps > params.bandHalfWidthBps) {
            revert InvalidParams();
        }
        if (params.feePips > MAX_FEE_PIPS) revert InvalidParams();
        if (params.performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert InvalidParams();
        if (params.maxStalenessSeconds == 0 || params.maxStalenessSeconds > MAX_STALENESS_SECONDS) {
            revert InvalidParams();
        }
    }
}
