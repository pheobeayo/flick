# Flick Team Guide

A plain-language tour of the codebase, then step by step instructions to deploy, verify and test Flick on Base Sepolia.

If you only read one section, read "The idea in two minutes".

---

## 1. The idea in two minutes

**The problem.** EURC/USDC is a currency pair. Its price should follow the real EUR/USD exchange rate. A normal Uniswap pool only changes price when someone trades in it, so when the real rate moves, the pool is briefly wrong. The first trader to notice buys the cheap side and sells it elsewhere. That profit is paid by the people who put money into the pool (the liquidity providers, or LPs).

**What Flick does.** Flick is a Uniswap v4 hook: a contract Uniswap calls automatically before every swap. Before each trade, Flick reads an exchange-rate feed (an oracle). If the rate has moved, Flick moves the pool to the new rate first, then lets the trade happen. Nobody gets to trade at an old price.

**How it can move the pool for free.** Flick's vault is the only liquidity in the pool. To move the price it removes all its liquidity (the pool is now empty), moves the empty pool's price to the oracle rate (an empty pool has nothing to trade against, so this costs nothing), and puts the liquidity back around the new price.

**When the feed cannot be trusted** (too old, revoked, or two feeds disagree), swaps stop. Withdrawals always keep working.

---

## 2. Words you will see

| Word          | Meaning                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------- |
| Pool          | A Uniswap market for two tokens. Here: EURC and USDC.                                             |
| Hook          | A contract Uniswap calls at fixed moments, such as before every swap. `FlickHook` is ours.        |
| Vault         | Flick's pot of tokens for one pool. People deposit into it and get shares.                        |
| Shares        | A claim on a fraction of the vault. Burn shares to withdraw that fraction.                        |
| Oracle / feed | A contract that reports the exchange rate. Chainlink in production, a mock we control on testnet. |
| Recenter      | Moving the vault's liquidity to the latest oracle rate.                                           |
| Band          | The narrow price range the vault's liquidity sits in, around the oracle rate.                     |
| Curator       | Whoever created the vault. Picks the settings and earns a cut of swap fees.                       |
| Guardian      | Safety role. Approves or revokes oracles, pauses vaults. Cannot move anyone's money.              |
| Base / quote  | Base is the currency being priced (EURC). Quote is what it is priced in (USDC).                   |
| bps           | Basis points. 100 bps = 1%.                                                                       |
| pips          | Fee units. 100 pips = 0.01%. 500 pips = 0.05%.                                                    |
| Tick          | Uniswap's internal price step. You rarely need to think about it.                                 |

---

## 3. What happens during a swap

1. A trader sends a swap to Uniswap.
2. Uniswap calls `FlickHook` before running it (`_beforeSwap`).
3. The hook checks the vault is not paused and reads the oracle.
4. If the price cannot be trusted, the swap is rejected with `SwapHalted`.
5. If the rate moved, the hook recenters (section 1).
6. The hook tells Uniswap which fee to charge.
7. Uniswap runs the trade at the current rate. The fee goes to the vault.

---

## 4. The codebase, file by file

Read in this order: `FlickTypes.sol`, then `FlickHook.sol`, then the tests.

### Contracts (`src/`)

| File                            | What it does                                                                                                                 |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `FlickHook.sol`                 | The whole product: creating vaults, deposits, withdrawals, recentering, fees, the swap check, guardian and curator controls. |
| `types/FlickTypes.sol`          | The data shapes: `Vault` (everything stored per pool), `VaultParams` (curator settings), `OracleStatus` (Normal or Halted).  |
| `interfaces/IFxOracle.sol`      | The shape every price feed must have: `latest()` returns a price and when it was observed.                                   |
| `oracles/ChainlinkFxOracle.sol` | Reads a real Chainlink feed and converts it to 18 decimals. Optionally checks Base's sequencer is up.                        |
| `oracles/MockFxOracle.sol`      | A feed whose price we set by hand. For tests and the demo only.                                                              |
| `libraries/FxMath.sol`          | Converts between "1 EURC = 1.15 USDC" and Uniswap's internal price format.                                                   |
| `libraries/BandMath.sol`        | Works out the band edges and whether the rate has moved enough to recenter.                                                  |

### Main functions in `FlickHook.sol`

| Who       | Function                                                               | What it does                                                             |
| --------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Curator   | `createVault`                                                          | Creates the pool at the oracle rate and seeds it with both tokens.       |
| Curator   | `queueParams` / `applyParams`                                          | Change settings. Waits 24 hours so depositors can leave first.           |
| Curator   | `claimCuratorFees`                                                     | Collects the curator's cut of swap fees.                                 |
| Anyone    | `deposit`                                                              | Pay both tokens in the vault's current mix, receive shares.              |
| Anyone    | `withdraw`                                                             | Burn shares, receive that fraction of both tokens. Always works.         |
| Anyone    | `recenter`                                                             | Move the liquidity to the latest rate now instead of waiting for a swap. |
| Guardian  | `setOracleApproved`                                                    | Approve a feed, or revoke it (which halts every vault using it).         |
| Guardian  | `setPaused`                                                            | Stop swaps and deposits for one vault.                                   |
| Guardian  | `transferGuardian` / `acceptGuardian`                                  | Hand the role to another address, for example a multisig.                |
| Read only | `getVault`, `oracleState`, `sharesOf`, `totalAssets`, `previewDeposit` | Look at a vault's state.                                                 |

### Scripts (`script/`)

| File                   | What it does                                                                                                                |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `00_DeployHook.s.sol`  | Deploys `FlickHook`. Uniswap requires hook addresses to encode their permissions, so it searches for a valid address first. |
| `01_CreateVault.s.sol` | Deploys a price feed (mock or Chainlink), approves it, creates and seeds the vault.                                         |
| `02_Swap.s.sol`        | Makes a swap and prints the oracle state, fee and vault centre before and after.                                            |
| `base/BaseScript.sol`  | Shared setup: finds Uniswap's contracts on the current chain.                                                               |

### Tests (`test/`)

| Folder                            | What it covers                                                                       |
| --------------------------------- | ------------------------------------------------------------------------------------ |
| `unit/`                           | The maths libraries, including fuzz tests with random inputs.                        |
| `oracles/`                        | Both price feed adapters.                                                            |
| `integration/FlickHook.t.sol`     | Vault creation, the swap check, oracle states, guardian handover.                    |
| `integration/FlickVault.t.sol`    | Deposits, withdrawals, shares, fees.                                                 |
| `integration/FlickRecenter.t.sol` | Recentering, curator settings, pause, and the plain pool vs Flick comparison.        |
| `integration/FlickSecurity.t.sol` | Tests for each security fix.                                                         |
| `utils/`                          | Shared setup. `BaseTest`, `Deployers` and `EasyPosm` come from the Uniswap template. |

---

## 5. Units cheat sheet

Most mistakes come from units. Every amount on-chain is a whole number.

| Thing              | Format               | Example                                        |
| ------------------ | -------------------- | ---------------------------------------------- |
| EURC, USDC amounts | 6 decimals           | 1 USDC = `1000000`                             |
| Oracle price       | 18 decimals          | 1.15 = `1150000000000000000`                   |
| Shares             | 18 decimals          | 1 share = `1000000000000000000`                |
| Swap fee           | pips                 | `500` = 0.05%                                  |
| Band, thresholds   | bps                  | `50` = 0.5%                                    |
| Deadlines          | Unix time in seconds | `$(($(date +%s) + 600))` = 10 minutes from now |

To turn a rate into an oracle price, multiply by 10^18: 1.1532 becomes `1153200000000000000`.

---

## 6. Run the tests

```bash
forge install          # first time only
forge build            # takes a few minutes the first time
forge test             # all 144 tests
forge test --match-test test_Arbitrage_PlainPoolLoses_FlickDoesNot -vv   # the headline comparison
forge test --match-path test/integration/FlickSecurity.t.sol -vvv        # one file, with traces
```

`-vv` prints logged numbers. `-vvvv` prints every call, which is useful when a test fails.

---

## 7. One-time setup for deploying

**1. Wallet.** Import your key into Foundry's encrypted keystore. You type it at a hidden prompt and it never sits in a file in the repo.

```bash
cast wallet import flick --interactive
```

**2. Test funds on Base Sepolia.**

- ETH for gas from any Base Sepolia faucet.
- EURC and USDC from faucet.circle.com (choose Base Sepolia). You need at least 11 of each.

**3. Verification key.** Create a free account on etherscan.io and copy an API key. The same key works for BaseScan.

**4. `.env` file** in the repo root. It is already in `.gitignore`, so it is never committed. Never put your private key in it.

```bash
RPC=https://sepolia.base.org
ME=0xYourWalletAddress
ETHERSCAN_API_KEY=YourEtherscanKey
BASE_TOKEN=0x808456652fdb597867f38412077A9182bf77359F
QUOTE_TOKEN=0x036CbD53842c5426634e7929541eC2318f3dCF7e
POOL_MANAGER=0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408
ROUTER=0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9
```

**5. Load it** at the start of every terminal session:

```bash
set -a; source .env; set +a
```

### Base Sepolia addresses

| Contract                        | Address                                      |
| ------------------------------- | -------------------------------------------- |
| EURC (base)                     | `0x808456652fdb597867f38412077A9182bf77359F` |
| USDC (quote)                    | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Uniswap v4 PoolManager          | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| Uniswap v4 PositionManager      | `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80` |
| Swap router used by our scripts | `0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9` |
| Permit2                         | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

---

## 8. Deploy and verify

Adding `--verify` to a deploy makes Foundry publish the source code on BaseScan in the same step.

**Step 1: deploy the hook.**

```bash
GUARDIAN=$ME forge script script/00_DeployHook.s.sol \
  --rpc-url $RPC --account flick --sender $ME --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

It prints `FlickHook: 0x...`. Add `HOOK=0x...` to `.env` and reload it.

**Step 2: create and seed the vault** with a mock price feed (10 EURC and 10 USDC, rate 1.15).

```bash
SEED_BASE=10000000 SEED_QUOTE=10000000 MOCK_PRICE=1150000000000000000 \
forge script script/01_CreateVault.s.sol \
  --rpc-url $RPC --account flick --sender $ME --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

It prints `Oracle:` and `Pool id:`. Add `ORACLE=0x...` and `POOL_ID=0x...` to `.env` and reload it.

Set `MOCK_PRICE` to today's EUR/USD rate times 10^18. The defaults in `01_CreateVault.s.sol` are: 0.5% band, recenter on any 0.01% move, 0.05% swap fee, curator keeps 10% of fees, swaps stop if the feed is older than 25 hours.

**Step 3: check on BaseScan.** Open `https://sepolia.basescan.org/address/<HOOK>`. The Contract tab should show a green tick. Do the same for the oracle.

### If verification did not happen

Run it by hand. For the hook:

```bash
forge verify-contract $HOOK src/FlickHook.sol:FlickHook \
  --chain base-sepolia --etherscan-api-key $ETHERSCAN_API_KEY --watch \
  --constructor-args $(cast abi-encode "constructor(address,address)" $POOL_MANAGER $ME)
```

For the mock oracle (use the same price you deployed it with):

```bash
forge verify-contract $ORACLE src/oracles/MockFxOracle.sol:MockFxOracle \
  --chain base-sepolia --etherscan-api-key $ETHERSCAN_API_KEY --watch \
  --constructor-args $(cast abi-encode "constructor(string,uint256)" "EUR / USD" 1150000000000000000)
```

If BaseScan says the bytecode does not match, check `foundry.toml` has not changed since the deploy. The compiler version, `optimizer`, `optimizer_runs` and `via_ir` must be the same.

---

## 9. The pool key

Many calls need the pool key: five values that identify the pool, in this order.

| Field       | Value            | Why                                                        |
| ----------- | ---------------- | ---------------------------------------------------------- |
| currency0   | USDC `0x036C...` | Uniswap orders the two tokens by address. USDC's is lower. |
| currency1   | EURC `0x8084...` |                                                            |
| fee         | `8388608`        | Means "the hook sets the fee".                             |
| tickSpacing | `10`             | Set in the scripts.                                        |
| hooks       | your `HOOK`      |                                                            |

Because USDC is currency0, `zeroForOne = true` means **selling USDC for EURC**, and `false` means selling EURC for USDC.

With cast, write the key as:

```bash
KEY="($QUOTE_TOKEN,$BASE_TOKEN,8388608,10,$HOOK)"
```

On BaseScan, write it as:

```
["0x036CbD53842c5426634e7929541eC2318f3dCF7e","0x808456652fdb597867f38412077A9182bf77359F",8388608,10,"0xYourHook"]
```

---

## 10. Testing with cast

Run these after loading `.env` and setting `KEY` as above. `cast call` only reads and costs nothing. `cast send` sends a transaction.

### Read the vault

```bash
# Oracle price, status (0 normal, 1 halted), swap fee
cast call $HOOK "oracleState(bytes32)(uint256,uint8,uint24)" $POOL_ID --rpc-url $RPC

# Tokens the vault holds (USDC first, then EURC, raw units)
cast call $HOOK "totalAssets(bytes32)(uint256,uint256)" $POOL_ID --rpc-url $RPC

# Your shares
cast call $HOOK "sharesOf(bytes32,address)(uint256)" $POOL_ID $ME --rpc-url $RPC

# Everything stored for the vault
cast call $HOOK "getVault(bytes32)((address,(uint8,uint8,bool),(address,address,uint16,uint16,uint16,uint24,uint16,uint64),uint256,int24,int24,uint128,uint256,uint256,uint256,uint256,uint256,bool))" $POOL_ID --rpc-url $RPC
```

### Keep the mock price fresh

If the mock price is more than 25 hours old, swaps stop. Refresh it before any test or demo:

```bash
cast send $ORACLE "setPrice(uint256)" 1150000000000000000 --rpc-url $RPC --account flick
```

### Swap

Easiest is the script. This sells 1 USDC:

```bash
AMOUNT_IN=1000000 SELL_BASE=false forge script script/02_Swap.s.sol \
  --rpc-url $RPC --account flick --sender $ME --broadcast
```

The same with cast (approve the router once, then swap):

```bash
cast send $QUOTE_TOKEN "approve(address,uint256)" $ROUTER 1000000 --rpc-url $RPC --account flick

cast send $ROUTER \
  "swapExactTokensForTokens(uint256,uint256,bool,(address,address,uint24,int24,address),bytes,address,uint256)" \
  1000000 0 true "$KEY" 0x $ME $(($(date +%s) + 600)) \
  --rpc-url $RPC --account flick
```

### See a recenter happen

```bash
# 1. The euro rises 1%
cast send $ORACLE "setPrice(uint256)" 1161500000000000000 --rpc-url $RPC --account flick

# 2. Swap with the script, or call recenter directly
cast send $HOOK "recenter((address,address,uint24,int24,address))" "$KEY" --rpc-url $RPC --account flick

# 3. The centre price in getVault (the 4th value) is now 1161500000000000000
```

### See the safety stop

```bash
# Pretend the price was last updated 26 hours ago
cast send $ORACLE "setPriceAt(uint256,uint64)" 1161500000000000000 $(($(date +%s) - 93600)) \
  --rpc-url $RPC --account flick
```

A swap now fails with `SwapHalted`, and `oracleState` shows status `1`. Run the "keep the mock price fresh" command to reopen.

### Deposit

```bash
# 1. What does 1 share cost? Returns (USDC, EURC) in raw units
cast call $HOOK "previewDeposit(bytes32,uint256)(uint256,uint256)" $POOL_ID 1000000000000000000 --rpc-url $RPC

# 2. Approve the hook to take both tokens (a little more than the preview)
cast send $QUOTE_TOKEN "approve(address,uint256)" $HOOK 2000000 --rpc-url $RPC --account flick
cast send $BASE_TOKEN "approve(address,uint256)" $HOOK 2000000 --rpc-url $RPC --account flick

# 3. Deposit for 1 share. The two maximums protect you from paying more than expected.
cast send $HOOK \
  "deposit((address,address,uint24,int24,address),uint256,uint256,uint256,address,uint256)" \
  "$KEY" 1000000000000000000 2000000 2000000 $ME $(($(date +%s) + 600)) \
  --rpc-url $RPC --account flick
```

### Withdraw

Works even when swaps are halted or the vault is paused.

```bash
cast send $HOOK \
  "withdraw((address,address,uint24,int24,address),uint256,uint256,uint256,address,uint256)" \
  "$KEY" 1000000000000000000 0 0 $ME $(($(date +%s) + 600)) \
  --rpc-url $RPC --account flick
```

The two zeros are the minimum USDC and EURC you accept. Use real minimums in production.

### Guardian actions

```bash
# Pause and unpause the vault
cast send $HOOK "setPaused(bytes32,bool)" $POOL_ID true --rpc-url $RPC --account flick
cast send $HOOK "setPaused(bytes32,bool)" $POOL_ID false --rpc-url $RPC --account flick

# Revoke the oracle (halts every vault using it), then approve it again
cast send $HOOK "setOracleApproved(address,bool)" $ORACLE false --rpc-url $RPC --account flick
cast send $HOOK "setOracleApproved(address,bool)" $ORACLE true --rpc-url $RPC --account flick

# Hand the guardian role to a multisig. The multisig must then call acceptGuardian().
cast send $HOOK "transferGuardian(address)" 0xMultisig --rpc-url $RPC --account flick
```

### Curator actions

```bash
# Collect the curator's share of swap fees
cast send $HOOK "claimCuratorFees((address,address,uint24,int24,address),address)" "$KEY" $ME \
  --rpc-url $RPC --account flick

# Queue new settings (here: swap fee 0.03%). Order: primary oracle, second oracle, band bps,
# recenter bps, max divergence bps, fee pips, curator fee bps, max staleness seconds.
cast send $HOOK "queueParams(bytes32,(address,address,uint16,uint16,uint16,uint24,uint16,uint64))" \
  $POOL_ID "($ORACLE,0x0000000000000000000000000000000000000000,50,1,100,300,1000,90000)" \
  --rpc-url $RPC --account flick

# 24 hours later, anyone can apply them
cast send $HOOK "applyParams(bytes32)" $POOL_ID --rpc-url $RPC --account flick
```

---

## 11. Testing on BaseScan

Once the contracts are verified, everything except swaps can be done in the browser.

1. Open `https://sepolia.basescan.org/address/<address>` and go to the **Contract** tab.
2. **Read Contract** needs no wallet. Paste the pool id (the `0x...` 32-byte value) into `oracleState`, `getVault`, `totalAssets` or `previewDeposit`.
3. **Write Contract**: click "Connect to Web3", connect your wallet on Base Sepolia, fill the fields, click "Write" and confirm in your wallet.

### Common tasks in the browser

| Task                          | Contract     | Function     | What to enter                                           |
| ----------------------------- | ------------ | ------------ | ------------------------------------------------------- |
| Change the mock rate          | Oracle       | `setPrice`   | `1161500000000000000`                                   |
| Simulate a stale feed         | Oracle       | `setPriceAt` | price, and a Unix time more than 25 hours ago           |
| Allow the hook to take tokens | USDC or EURC | `approve`    | spender = hook, value = raw amount                      |
| Deposit                       | Hook         | `deposit`    | key, shares, max USDC, max EURC, your address, deadline |
| Withdraw                      | Hook         | `withdraw`   | key, shares, 0, 0, your address, deadline               |
| Recenter                      | Hook         | `recenter`   | key                                                     |
| Pause                         | Hook         | `setPaused`  | pool id, `true`                                         |

USDC and EURC are proxy contracts. To approve on BaseScan, use **Write as Proxy** on the token's page, not Write Contract.

For the deadline, use a Unix time a few minutes ahead. epochconverter.com shows the current one.

**Swaps:** use the script or cast in section 10. The router's Write tab may not be available on BaseScan, and swaps need a token approval for the router first.

---

## 12. When something fails

Hook errors appear inside a `WrappedError` when they happen during a swap. Look for the inner code.

| Error                 | Code         | Usual cause                                                                        | Fix                                              |
| --------------------- | ------------ | ---------------------------------------------------------------------------------- | ------------------------------------------------ |
| `SwapHalted`          | `0x53ca1a38` | Feed too old, revoked, or feeds disagree                                           | Refresh the mock price, or re-approve the oracle |
| `VaultPaused`         | `0xda9f8b34` | Guardian paused the vault                                                          | `setPaused(poolId, false)`                       |
| `SlippageExceeded`    | `0x8199f5f3` | Deposit cost more than your maximums, or a withdrawal paid less than your minimums | Re-check `previewDeposit` and raise the limits   |
| `DeadlinePassed`      | `0x70f65caa` | The deadline was in the past                                                       | Use a time a few minutes ahead                   |
| `InsufficientShares`  | `0x39996567` | Withdrawing more shares than you own                                               | Check `sharesOf`                                 |
| `OracleNotApproved`   | `0x12da196c` | Oracle not approved by the guardian                                                | `setOracleApproved(oracle, true)`                |
| `OracleNotFresh`      | `0x7d3232f6` | Creating a vault with a stale feed                                                 | Refresh the price first                          |
| `RecenterNotNeeded`   | `0x5a310b4f` | Rate has not moved, or the feed is not trusted                                     | Move the price, or refresh the feed              |
| `ParamsNotReady`      | `0xcb32a959` | Applying settings before the 24 hours are up                                       | Wait                                             |
| `OracleSwitchTooFar`  | `0x4fb72e12` | New feed is more than 5% from the current rate                                     | Use a feed for the same pair                     |
| `NotGuardian`         | `0xef6d0f02` | Only the guardian can do this                                                      | Use the guardian wallet                          |
| `NotCurator`          | `0x56b381a5` | Only the curator can do this                                                       | Use the curator wallet                           |
| `VaultNotFound`       | `0xdee790fb` | Wrong pool id or key                                                               | Use the values printed by the create script      |
| ERC20 allowance error | `0xfb8f41b2` | Token approval missing or too small                                                | Approve the hook (deposits) or router (swaps)    |

To identify an unknown code: `cast 4byte 0x53ca1a38`.

---

## 13. Rules the contract enforces

- Pools can only be created through `createVault`, always at the oracle rate.
- Only the vault can add liquidity. Outsiders are rejected.
- Swaps only run when the price is fresh, approved and, if there are two feeds, confirmed.
- Withdrawals never read the oracle and cannot be paused.
- Deposits and withdrawals use the vault's current mix of tokens, not a price, so they cannot be used to trade at a stale rate.
- Settings changes wait 24 hours, must stay inside fixed limits, and cannot switch to a feed more than 5% away.
- The guardian can halt and pause but cannot move funds.

Known limits are listed in the README under Security.
