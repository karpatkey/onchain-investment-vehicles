# Splitting an OIV's fees between recipients (0xSplits PushSplit)

## What it is

A fund pays every fee to one address, `feeReceiver`. To share fees between several parties, point
`feeReceiver` at a **0xSplits PushSplit** (Splits v2.2): a small contract that holds what it receives
and pays it out to fixed recipients in fixed proportions when anyone calls `distribute`.
This repository deploys none of it. It calls the canonical contracts 0xSplits already deployed, and
carries a minimal interface ([`IPushSplit`](../src/interfaces/IPushSplit.sol),
[`IPushSplitFactory`](../src/interfaces/IPushSplitFactory.sol)), the batches and the tests.

Use it when two or more parties are owed a fixed share of a fund's fees. Do not use it for a single
recipient (set that address as `feeReceiver` directly).

| Question | Answer |
|---|---|
| Who gets paid | The recipients written into the split, in the allocations written into it |
| In what | Fund shares (see below), not USD |
| Who triggers payment | Anyone, by calling `distribute` on the split. Nothing is automatic |
| Who can change recipients | Nobody, when the split is created with owner `0x0000000000000000000000000000000000000000` (recommended) |
| Cost to set up | One permissionless create transaction, one timelocked `setFeeReceiver` |

## How a kpkShares fund pays fees, and what changes

Source: [`src/kpkShares.sol`](../src/kpkShares.sol), see also [KpkShares.md](KpkShares.md#4-fee-management).

| Fee | Function | What happens to `feeReceiver` |
|---|---|---|
| Management | `_chargeManagementFee` | New shares are minted to it |
| Performance | `_chargePerformanceFee` | New shares are minted to it |
| Redemption | `_chargeRedemptionFee` | Shares are transferred to it out of the redeemer's escrowed shares |
| Changing it | `setFeeReceiver` | Admin only. For a timelocked fund the admin is the shares timelock, so the change waits the timelock delay |

Shares held by `feeReceiver` are left out of the base the management and performance fees are
charged on (`totalSupply() - balanceOf(feeReceiver)`), so the receiver never pays a fee on its own fees.

When `feeReceiver` is a split:

- The split receives the fee shares. Nothing else about the fund changes.
- After `distribute`, each recipient holds fund shares and redeems them like any holder, through
  `requestRedemption`.
- Shares held by the split are excluded from the fee base, as for any `feeReceiver`. Shares held by the
  recipients after a distribution are ordinary shares and are charged fees like anyone's.

## Canonical addresses (Ethereum and Robinhood Chain 4663)

Source: upstream `packages/splits-v2/deployments/1.json` and `4663.json`; code read from both chains.
Robinhood Chain (4663) at block 120858887, 2026-11-22T19:47:19Z; Ethereum at block 26472836.

| Contract | Address | Size | Codehash on 4663 | Codehash on Ethereum |
|---|---|---|---|---|
| PushSplitFactory v2.2 | `0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4` | 3,030 bytes | `0x7289581fdbc21ec0b07d4f34c870a5548a03564691d6e24ef9c770134f8e95fb` | same |
| PushSplit implementation (what the factory clones) | `0x1e2086A7e84a32482ac03000D56925F607CCB708` | 10,300 bytes | `0xe2dfdf9b01f082ac22a1a4d91a2887eea93ffeaa6431ed262f8efcf4de1291f7` | `0xd03d1b6c36959af2f2d340ac9e0996c528aa88bcc0bb41461929a6bb2ba064bb` |
| SplitsWarehouse | `0x8fb66F38cF86A3d5e8768f8F1754A24A6c661Fb8` | 12,146 bytes | `0x816de1e108ecca3ab0a28b281c6e2443659ef372235d6a9bb72b101c784eebb1` | `0x6db5122c3a5501ebf1391cb815e07bfebb1f4fa80c1d45aa30de372db65534ab` |
| PullSplitFactory v2.2 (not used here) | `0x6B9118074aB15142d7524E8c4ea8f62A3Bdb98f1` | | | |

- The factory's `SPLIT_WALLET_IMPLEMENTATION()` returns the implementation above.
- The two PushSplit runtimes differ in exactly 34 bytes: the cached EIP-712 domain separator (32 bytes at
  offset 9664) and the cached chain id (`0x1237` on 4663, `0x01` on Ethereum, at offset 9898). The code is
  otherwise the same. The warehouse differs in the same two places plus the trailing 32-byte solc metadata hash.
- A PushSplit reads its balance in the warehouse and withdraws from it only when that balance is above 1.
  A fee split does not use the warehouse.
- The 4663 values are asserted by `test/FeeSplitCrossbowFork.t.sol`. The Ethereum values were read once, as above.

## The recipe, for any fund

1. **Choose the parameters.**

   | Parameter | Meaning | Recommendation |
   |---|---|---|
   | recipients | Who is paid | Addresses that can hold and redeem the shares. A Safe or an EOA, never an address that cannot act |
   | allocations | One weight per recipient | Any integers |
   | totalAllocation | Must equal the sum of the allocations | `1000000` makes the weights parts per million |
   | distributionIncentive | Share of each distribution paid to whoever calls `distribute`, parts per 1e6 | `0`, unless you want a keeper paid |
   | owner | Who can change the split | **`0x0000000000000000000000000000000000000000`** |
   | salt | Tells otherwise identical splits apart | `keccak256("<fund>-fee-split-v1")` |

   Why owner `0`: an owner can re-point the split to other recipients (`updateSplit`), pause it
   (`setPaused`), and take everything it holds (`execCalls`). With no owner none of that is reachable
   by anyone, so the recipients and shares are fixed for good, and nothing can be paused or swept.

2. **Predict the address** and check it is free (the factory's `isDeployed` returns `(address, exists)`):

   ```sh
   SPLIT="([<recipient1>,<recipient2>],[<alloc1>,<alloc2>],<total>,<incentive>)"
   SALT=$(cast keccak "<fund>-fee-split-v1")
   cast call 0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4 \
     "isDeployed((address[],uint256[],uint256,uint16),address,bytes32)(address,bool)" \
     "$SPLIT" 0x0000000000000000000000000000000000000000 $SALT --rpc-url $RPC
   ```

3. **Create the split.** Permissionless: any address may send it, and a third party creating it first
   is harmless (same address, and the later call returns that address instead of reverting). The
   `creator` argument is only written to the event. Build the calldata, for a Safe batch:

   ```sh
   cast calldata "createSplitDeterministic((address[],uint256[],uint256,uint16),address,address,bytes32)" \
     "$SPLIT" 0x0000000000000000000000000000000000000000 <creator> $SALT
   ```

4. **Schedule `setFeeReceiver(split)`** on the fund's shares timelock, from the account that holds the
   timelock's proposer role:

   ```sh
   DATA=$(cast calldata "setFeeReceiver(address)" <split>)
   OPSALT=$(cast keccak "<fund>-fee-receiver-split-v1")
   ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
   cast calldata "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
     <shares> 0 $DATA $ZERO $OPSALT <delay>
   # operation id, to look up later:
   cast call <timelock> "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
     <shares> 0 $DATA $ZERO $OPSALT --rpc-url $RPC
   ```

5. **Execute after the delay.** `execute` is open to any address and reverts before the delay has passed:

   ```sh
   cast calldata "execute(address,uint256,bytes,bytes32,bytes32)" <shares> 0 $DATA $ZERO $OPSALT
   ```

   Check `cast call <shares> "feeReceiver()(address)"` returns the split.

6. **Pay out, whenever you like.** Anyone, any time after fee shares have accrued to the split. The
   struct passed in must be the one the split was created with:

   ```sh
   cast send <split> "distribute((address[],uint256[],uint256,uint16),address,address)" \
     "$SPLIT" <shares> <distributor> --rpc-url $RPC
   ```

Do all of this on a fork first. [`test/FeeSplitCrossbowFork.t.sol`](../test/FeeSplitCrossbowFork.t.sol)
is a worked example to copy.

## Limits and risks

| Limit | What it means |
|---|---|
| Not automatic | Fees sit in the split as fund shares until someone calls `distribute`. A recipient, or any keeper, must do it |
| Not retroactive | Fee shares minted before `setFeeReceiver` executes went to the old receiver. Splitting those is a separate, offchain matter |
| Fixed forever (owner 0) | Changing recipients or shares means a new split and another timelocked `setFeeReceiver`, which takes the timelock delay and is visible onchain |
| Paid in fund shares | Recipients get shares, not USD. They redeem through the fund's normal request flow and carry the fund's price risk until they do |
| All or nothing | `distribute` reverts entirely if any single transfer reverts, for example to a recipient that cannot receive the token. Choose recipients that can |
| 1 wei dust | A distribution leaves 1 wei of the token in the split on purpose. Rounding can leave a little more |
| A lost or stolen recipient key | The recipient's share goes with the key. Nothing in the split can redirect it, because the split cannot be changed. Prefer a Safe as recipient |
| Audit coverage | The audit report in the upstream repo (`audits/splits-v2.md`, Zach Obront) covers Splits V2 up to commit `740abb43a8961379cbe53cd2fd28287f28a47556` (March 2024). v2.1 (upstream PR #55, December 2024) and v2.2 (upstream PR #65, July 2025) came later. The upstream repo holds no audit report for those changes |
| Third-party code | Funds sent to a split depend on contracts this repository neither wrote nor controls. The recipe above uses only the canonical deployment listed in the table |

## The Crossbow instance (xbUSDG)

The Crossbow USDG Liquidity fund on Robinhood Chain (4663) is the recorded instance.

**Status: NOT executed.** At block 120858887 on 4663 (2026-11-22T19:47:19Z): no code at the split
address, xbUSDG `feeReceiver()` still the KPK fee Safe `0x9F230218cf7FDe6A9246e6f8CB0b888377E92639`,
the timelock operation's `getTimestamp` 0, xbUSDG `totalSupply()` 0. The three batches are prepared
and unsigned. The split is not deployed; [DEPLOYED_ADDRESSES.md](DEPLOYED_ADDRESSES.md) does not list it.

| Item | Value |
|---|---|
| Fund shares (xbUSDG) | `0x622609130ae8fCe48c80EEc4DB95759a76737c03` |
| Shares timelock (delay 259200 s, 3 days) | `0x4F96c1FE0Af339Ce11a9c621b73Bbd201d2f8109` |
| Governance Safe (2 of 6) | `0x2F0d561B9a8CD981e6E73069592BDeA4e48A8bec` |
| Security Council Safe (5 of 8) | `0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537` |
| Manager Safe (operator) | `0x74d7aFCf8d44ec6932afA4Cb4B6e2b799C1d4b84` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Recipient 1, allocation 500000 | `0x8680f51Da765288EA163Cd971f0D535A41e37851` (Crossbow, an EOA) |
| Recipient 2, allocation 500000 | `0x9F230218cf7FDe6A9246e6f8CB0b888377E92639` (KPK fee Safe) |
| totalAllocation / distributionIncentive / owner | `1000000` / `0` / `0x0000000000000000000000000000000000000000` |
| Salt | `keccak256("crossbow-usdg-fee-split-v1")` = `0x16cc1a8ad3b23e6995b5b9364d9b8559f81ef1b55c20ef26640e79290df83a9c` |
| Predicted split | `0x581A8f9d85269f6Da997a9375b51752E564D1aeA` (factory `isDeployed` returned this with `exists == false`) |
| `setFeeReceiver` operation salt | `keccak256("crossbow-usdg-fee-receiver-split-v1")` = `0xe38048aeb1cde2fd1982140a6e14702d7254cef933b63c17bb8b86e9f396dd3f` |
| Operation id (predecessor 0) | `0xf6e395b1b9138e3ac239fe1f6b5958c88629aca7f3d0de948f131dbc2dc85821` |

The batches are in [`script/safe-txs/fee-split-crossbow/`](../script/safe-txs/fee-split-crossbow/)
(parameters in its `manifest.json`). Execute in this order:

| # | File | Sent by | Calls |
|---|---|---|---|
| 1 | `1-governance-create-split.json` | Governance Safe | `createSplitDeterministic(split, 0x0000000000000000000000000000000000000000, 0x2F0d561B9a8CD981e6E73069592BDeA4e48A8bec, salt)` on the PushSplitFactory `0x8E8eB0cC6AE34A38B67D5Cf91ACa38f60bc3Ecf4`. Creates the split at `0x581A8f9d85269f6Da997a9375b51752E564D1aeA` |
| 2 | `2-council-schedule-fee-receiver.json` | Security Council Safe | `schedule(0x622609130ae8fCe48c80EEc4DB95759a76737c03, 0, setFeeReceiver(0x581A8f9d85269f6Da997a9375b51752E564D1aeA), 0x00, 0xe38048aeb1cde2fd1982140a6e14702d7254cef933b63c17bb8b86e9f396dd3f, 259200)` on the shares timelock `0x4F96c1FE0Af339Ce11a9c621b73Bbd201d2f8109`. The Council can cancel until step 3 |
| 3 | `3-execute-fee-receiver.json` | Governance Safe (any address may send it) | `execute(0x622609130ae8fCe48c80EEc4DB95759a76737c03, 0, setFeeReceiver(0x581A8f9d85269f6Da997a9375b51752E564D1aeA), 0x00, 0xe38048aeb1cde2fd1982140a6e14702d7254cef933b63c17bb8b86e9f396dd3f)` on the same timelock, at least 259200 s after step 2 lands |

What the tests show (both under `test/`):

- `FeeSplitBatches.t.sol`, offline, runs in CI: each batch's calldata equals what its manifest
  parameters encode to, and the operation id derived from it equals the manifest's.
- `FeeSplitCrossbowForkTest` (`FeeSplitCrossbowFork.t.sol`), a fork of 4663 at block 120858887, skipped
  without `RH_URL`: the three committed batches replayed from their Safes. The split lands at the
  predicted address with owner 0; the Governance Safe, the Council and a stranger cannot
  `updateSplit`, `setPaused` or `execCalls`; only the Council can schedule; `execute` reverts one second
  before the delay and works from any address after it; `feeReceiver()` becomes the split. A real fee
  (subscribe 1000 USDG, settle at 1.00, settle at 1.10 seven days later) mints 9.090909090909090909
  xbUSDG to the split and none to the KPK fee Safe; a third party's `distribute` pays each recipient
  4.545454545454545454 xbUSDG and leaves 1 wei; the Crossbow address can then request redemption.

Fees minted before step 3 still go to `0x9F230218cf7FDe6A9246e6f8CB0b888377E92639`. Crossbow's half of
those is paid offchain.

## Attribution and license

| | |
|---|---|
| Credit | 0xSplits, https://splits.org. Upstream: https://github.com/0xSplits/splits-contracts-monorepo, package `packages/splits-v2` |
| Read at | commit `23e9ef64c918205214fc23b2ff89fa590a32efc2` (main, 2026-11-12). v2.2 landed in upstream PR #65 (commit `31f55f1332`, 2025-07-07) |
| Upstream license | GNU GPL v3 (root `LICENSE`); every `packages/splits-v2/src/**.sol` carries `SPDX-License-Identifier: GPL-3.0-or-later` |
| This repository | `SPDX-License-Identifier: MIT` on every source |

How this repository stays inside that:

- It copies no upstream source, NatSpec, comments or tests, has no submodule of upstream, and imports no
  upstream code.
- It deploys no 0xSplits code. It sends transactions to the contracts 0xSplits already deployed.
- `IPushSplit` and `IPushSplitFactory` are independent interfaces written from the public ABI: function,
  event and error signatures and the `Split` struct layout, with this repository's own NatSpec. Each
  credits 0xSplits and links the upstream files at the commit above.

If anyone later vendors or imports upstream 0xSplits code into this repository (a copy of a contract, a
submodule, an `import` of an upstream file), the copied files stay GPL-3.0-or-later, the GPL-3.0 text must
ship with them, and every file that imports them can only be distributed under GPL-3.0-or-later terms. The
MIT headers in this repository would then be wrong for those files. Do that only as a deliberate licensing
decision, not as a convenience.
