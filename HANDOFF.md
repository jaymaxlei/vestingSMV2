# IDOS Staking-Aware Vesting — full handoff

Paste this into a fresh AI conversation to continue the work. Everything an
LLM needs to pick up where Julian left off is below: the original problem,
the on-chain state, the design decisions, the deployed test wallet, and the
outstanding tasks.

Repo: **https://github.com/jaymaxlei/vestingSMV2** (default branch `main`).

---

## 1. TL;DR — state at handoff

- The existing IDOS distribution system (factory `TDEDisbursement` at
  `0xdf24F4Ca9984807577d13f5ef24eD26e5AFc7083`) shipped **20,070 wallets** for
  the "FCL Months 2-6" cohort with the **wrong modality**: they got
  `VESTED_1_5` (≈5-month linear vest with a 31-day cliff) instead of the
  intended "6 months, no cliff".
- Unvested IDOS in those wallets is **completely inert** — the deployed
  `IDOSVesting` is a vanilla OpenZeppelin `VestingWallet + VestingWalletCliff`
  with no `approve`, no `call`, no `delegate`. The IDOS token is plain ERC20
  with `ERC20Permit` but no `ERC20Votes`, no `ERC1363`, no hooks. There is no
  on-chain path from a vesting wallet into the `IDOSNodeStaking` contract.
- A **new** wallet type — `IDOSStakingVesting` — has been designed,
  implemented, hardened, tested in a Foundry fork suite, and **deployed live**
  to Arbitrum One as a 4-hour same-day end-to-end test. Phase 1 (deploy +
  stake + release + unstake + negative-test withdrawal) is **confirmed
  working on mainnet**. Phase 2 (final withdraw + release after the 14-day
  unstake delay) is scripted and waiting for 2026-05-29 onwards.
- No changes were needed to `IDOSNodeStaking` or `IDOSToken`. Everything is
  on the vesting-wallet side.

---

## 2. Key on-chain addresses (Arbitrum One, chain id 42161)

| Role | Address |
| --- | --- |
| IDOS token (ERC20 + Burnable + Permit) | `0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c` |
| IDOSNodeStaking (deployed staking) | `0x6132F2EE66deC6bdf416BDA9588D663EaCeec337` |
| TDEDisbursement v1 (existing factory) | `0xdf24F4Ca9984807577d13f5ef24eD26e5AFc7083` |
| Staking owner / treasury | `0xd5259b6E9D8a413889953a1F3195D8F8350642dE` |
| Live test vesting wallet | `0xbe7a0Fd150216273Ff879F25902dC2761A0d4CA6` |
| Live test beneficiary EOA | `0x1bCE6d61F2cFE40F0879b17a43780695CbCc19ff` |
| Live test target staking node | `0x0C5393db793DbA88f16DC4D030D678FBD88F8B0D` |
| Example "wrong-modality" wallet inspected | `0x03E2C8D6F41dbB014edc970CD0932C148D60A68C` (modality 8 = VESTED_12_24) |

Etherscan-style API:
`https://api.etherscan.io/v2/api?chainid=42161&...` with API key
`5UTYFKS14T3SX6JU5GB1M8MSQHQSJQGJ5M` (Julian's read-only key).

RPC: `https://arb1.arbitrum.io/rpc`.

---

## 3. The original f-up

`TDEDisbursement` (verified source on Arbiscan) defines 10 modalities. Each
modality is `(startTimestamp, durationSeconds, cliffSeconds)`:

| # | Name | start | duration | cliff |
|---|---|---|---|---|
| 0 | DIRECT | – | – | – |
| 1 | VESTED_0_12 | 2026-02-05 | 1 y | 28 d |
| 2 | VESTED_0_120 | 2026-02-05 | 10 y | 28 d |
| **3** | **VESTED_1_5** | **2026-03-05** | **153 d (~5 mo)** | **31 d** |
| 4 | VESTED_1_6 | 2026-03-05 | 184 d (~6 mo) | 31 d |
| 5 | VESTED_1_60 | 2026-03-05 | 5 y | 31 d |
| 6 | VESTED_6_12 | 2026-08-05 | 1 y | 31 d |
| 7 | VESTED_6_24 | 2026-08-05 | 731 d (2 y) | 31 d |
| 8 | VESTED_12_24 | 2027-02-05 | 731 d (2 y) | 28 d |
| 9 | VESTED_12_36 | 2027-02-05 | 1095 d (3 y) | 28 d |

The disburser fired the airdrop with `modality = 3` (VESTED_1_5) for the
**FCL Months 2-6** cohort. Intended: 6 months / no cliff. Actual: ~5 months
with a 31-day cliff. All 20,070 wallets in that cohort are affected (count
verified by cross-referencing `logs (1).json` deploy events against
`[LOCKED] Vesting Master List … Only FCL Months 2-6.csv`).

Today's date (handoff time): **2026-05-15**. So:

- FCL Months 2-6 wallets are past the (unintended) cliff (2026-04-05) and
  ~46% vested today. They can `release()` what's vested into the
  beneficiary's EOA and stake those tokens themselves — but **only what has
  been released**. The locked portion has no path to staking.
- Long-vest cohorts (modality 8/9, ~24 wallets) have everything locked
  until 2027-02-05 at earliest. No on-chain rescue exists for those wallets.

The IDOSToken (`0x68731d…d79c`) is verified as:

```solidity
contract IDOSToken is ERC20, ERC20Burnable, ERC20Permit {
    constructor(address initialTreasury)
        ERC20("IDOSToken", "IDOS") ERC20Permit("IDOSToken")
    { _mint(initialTreasury, 1_000_000_000 * 10 ** decimals()); }
}
```

No `ERC20Votes`, no `ERC20Snapshot`, no `ERC1363`, no hooks. `permit()` uses
`ECDSA.recover` only (no EIP-1271), so contracts can't sign approvals on
their own behalf. That closes every imaginable escape hatch for the existing
`IDOSVesting` wallets.

---

## 4. The solution: `IDOSStakingVesting`

A new vesting wallet that inherits the same OZ `VestingWallet +
VestingWalletCliff` as the v1, plus four beneficiary-only functions
(`stakeAt`, `unstakeFrom`, `withdrawUnstaked`, `withdrawReward`) and a
permissionless convenience helper (`claimVested`). The vesting math
(`vestedAmount()`) is overridden to count tokens currently sitting at the
staking contract toward the total allocation — net of any slashing — so that
`release()` pays the right amount even while the wallet's own balance has
been drained into staking.

Key design property: **no changes to `IDOSNodeStaking` are required.** The
staking contract's `stake(user, node, amount)` already accepts an arbitrary
`user`, so a smart-contract wallet that can call `approve(staking, amount)`
and `staking.stake(self, node, amount)` participates natively.

Source: `src/IDOSStakingVesting.sol`. Companion factory:
`src/TDEDisbursement2.sol` (drop-in replacement for v1; same modality table,
fresh CREATE2 salt namespace).

### Hardenings I added during the adversarial pass

1. **Constructor rejects zero token/staking addresses.**
2. **`vestedAmount()` clamps to `Math.max(_vestingSchedule(...), released(token))`.**
   Without this, if a beneficiary releases some tokens and a slashing event
   then drops total allocation below what's already paid, `releasable()`
   underflows and bricks all future releases. With it, the contract stays
   solvent.
3. **`claimVested()` convenience** — single-tx `try { withdrawUnstaked() }
   catch {} ; release(IDOS)`. Permissionless on purpose: every path is
   beneficiary-favourable.

Things I considered but **did not** change (decisions for the team):

- `renounceOwnership()` is inherited; if called, future `release()` would
  burn IDOS to `address(0)`. Matches v1 behaviour. If you want it disabled,
  override and revert.
- Slashing is a real economic loss; the contract handles it gracefully but
  cannot undo it.

---

## 5. Test coverage

`test/Adversarial.t.sol` is a 400-line Foundry suite probing three
questions explicitly:

**Q1 — Can it be gamed?** Verdict: no.

- `round_trips_dont_drift` — multi-cycle stake/unstake mid-vest doesn't
  shift the result of `release()` at 50% of duration.
- `cannot_release_more_than_schedule` — 8 rapid cycles, then release at
  25% elapsed: paid ≤ 35% of principal.
- `overstake_reverts` — staking more than the wallet holds reverts via
  the underlying `safeTransferFrom`.

**Q2 — Can vesting be circumvented?** Verdict: no.

- `t0_nothing_leaks` — full stake/unstake/claim sequence at schedule start
  yields <2% of principal (only time-vesting that occurred during the
  15-day unstake-delay warp).
- `only_beneficiary_can_stake_etc` — non-owner reverts with
  `OnlyBeneficiary`.
- `third_party_release_pays_beneficiary` — OZ release is permissionless
  but tokens always go to `owner()`.
- `no_external_allowance` — no allowance leaks; `forceApprove` is fully
  consumed inside the same `STAKING.stake` call.
- `transfer_ownership_doesnt_unlock` — new owner still bound by schedule.
- `reentrant_owner_cannot_drain` — reentrant fallback on `release` can't
  extract more than vested.

**Q3 — Can tokens get stuck in the staking contract?** Verdict: no
permanent stuck states. One temporary stuck state (slashing) is by-design.

- `premature_withdraw_does_not_lose` — withdraw before 14 days reverts;
  queue is preserved; 13 days later it succeeds.
- `full_lifecycle_returns_everything` — after full duration + unstake +
  14d, beneficiary holds 100% of principal.
- `slashing_lost_but_rest_releasable` — slash on one node loses that
  share; rest still claimable; `release()` never underflows even when
  total drops below already-released.
- `pause_then_unpause_recovers` — staking pause is recoverable.

Run with:

```
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.5.0 --no-git --shallow
ARB_RPC=https://arb1.arbitrum.io/rpc forge test --fork-url $ARB_RPC -vv
```

(macOS users: `brew install foundry` first.)

---

## 6. Live test on Arbitrum One — Phase 1 done, Phase 2 pending

Same-day test of a 4-hour / no-cliff schedule.

| Step | Tx | Result |
|---|---|---|
| Deploy + fund 100 IDOS | bundled in `Live.s.sol` broadcast | wallet `0xbe7a0Fd1…4CA6` |
| `stakeAt(node, 50 IDOS)` | `0xf0364627274f56b6e4929cb2252ad6a6032fac5480d891d8d02d128d475131ef` | 50 IDOS moved wallet→staking; `outstandingStake = 50e18`; `stakeByNodeByUser = 50e18` |
| `release(IDOS)` at T+1069s (7.42% of 4h elapsed) | `0x78378500fed7858bff26ab9f3ba3024214728df5e722a018a6050e1ab79cb5d4` | Paid **7.458 IDOS** — proportional to the **full 100 IDOS** allocation, not the residual 42.54 in the wallet. Confirms the stake-aware override works in production. |
| `unstakeFrom(node, 50 IDOS)` | `0x7e53423e3b432864678d14d40aa2075fd650c7c50553bf56a4b6d6da6e849b71` | per-node position drained to 0; queued in `unstakesByUser` |
| `withdrawUnstaked()` immediately afterward | reverted at gas estimation | `NoWithdrawableStake` (selector `0xf395c842`) — 14-day delay enforced ✓ |

**Headline result**: if the override of `vestedAmount()` were broken, the
T+1069s release would have paid ~3.7 IDOS (linear schedule against the
residual 42.54 in the wallet). It paid **7.458** — exactly what the schedule
produces against the *full* 100 IDOS, confirming the `outstandingStake`
accounting flows correctly through `release()` in production.

### Phase 2 — withdraw + final release (T+14d)

The unstake transaction landed on 2026-05-15 ~13:35 local. The 14-day
`UNSTAKE_DELAY` opens on **2026-05-29**. After that:

```sh
PRIVATE_KEY=<beneficiary key> ./script/LiveFinish.sh
```

does `withdrawUnstaked()` then `release(IDOS)`, and asserts the closing
state: wallet IDOS = 0, beneficiary IDOS = 200 IDOS, `released() = 100e18`,
`outstandingStake = 0`.

**Test private key — REDACTED / COMPROMISED.** The original key was briefly
included in this file when it was first published, was visible in the public
GitHub repo for a few minutes, and must be assumed leaked permanently
(leaked-key scrapers on GitHub act in seconds). The corresponding EOA
`0x1bCE6d61F2cFE40F0879b17a43780695CbCc19ff` **must not be used for anything
further** and any remaining IDOS / ETH on it should be treated as at risk.

For Phase 2, transfer ownership of the test wallet to a fresh EOA the team
controls **before** the 14-day unstake delay elapses (2026-05-29):

```sh
cast send 0xbe7a0Fd150216273Ff879F25902dC2761A0d4CA6 \
  'transferOwnership(address)' <NEW_OWNER_ADDRESS> \
  --rpc-url https://arb1.arbitrum.io/rpc --private-key <compromised key>
```

then run `script/LiveFinish.sh` (or the two `cast send` lines inside it)
from the new EOA after the delay opens.

---

## 7. Outstanding work (in priority order)

1. **Run `script/LiveFinish.sh` on/after 2026-05-29** to close out the live
   test. Either set a calendar reminder and run manually, or ask a fresh
   Claude turn to create the `idos-vesting-live-finish` scheduled task
   (`scheduled-tasks` skill — requires the approval dialog that auto-mode
   can't surface).
2. **Decide treatment of the 20,070 FCL Months 2-6 wallets.** They are past
   cliff and ~46% vested today. Options:
   - Do nothing — let them drip on the (slightly short) schedule. Loss to
     recipients: ~5 weeks of foregone staking yield on the cliff-locked
     portion, and one extra month of unintended lockup at the end.
   - Top up via a new `IDOSStakingVesting` deployment with the corrected
     schedule (6 months, no cliff) for the missing month.
   - Buy back / compensate off-chain.
3. **Decide treatment of the modality 8/9 long-vest wallets** (24 total).
   Their tokens are locked until 2027-02-05 at earliest. On-chain rescue is
   impossible. Off-chain treasury action only.
4. **Roll out `TDEDisbursement2`** for any future distributions, so new
   wallets ship with staking capability built in. ~30 lines of changes from
   v1; CREATE2 salt namespace already shifted to `"IDOSStakingVesting.v2"`.
5. **Third-party audit** before any large-value deployment of
   `IDOSStakingVesting`. The contract is small (~100 lines + OZ) and the
   override surface is concentrated in `vestedAmount`, so this should be a
   short engagement.
6. **Optional UX polish**: a single-tx `claim(node, amount)` that bundles
   `unstakeFrom` (and remembers the timestamp), with a separate
   `finalizeClaim()` after the 14 days. Today the beneficiary has to
   manually choreograph the two steps.

---

## 8. Quick-start commands

```sh
# Clone
git clone https://github.com/jaymaxlei/vestingSMV2.git
cd vestingSMV2

# Install dependencies
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.5.0 --no-git --shallow

# Build
forge build

# Adversarial test suite (Arbitrum fork)
ARB_RPC=https://arb1.arbitrum.io/rpc forge test --fork-url $ARB_RPC -vv

# Deploy a new wallet (36-month schedule, no cliff)
BENEFICIARY=0x… PRIVATE_KEY=0x… \
  forge script script/Deploy.s.sol --rpc-url https://arb1.arbitrum.io/rpc --broadcast

# Finish the live test (2026-05-29 onwards)
# First transfer wallet ownership from the compromised EOA to a new one,
# then run the closer from that new EOA:
PRIVATE_KEY=<new beneficiary key> ./script/LiveFinish.sh
```

---

## 9. Files in the repo (commit `e26ee6e`)

```
.gitignore
foundry.toml                       — solc 0.8.28, EVM "cancun", optimizer 200
README.md                          — overview + 36-month canonical schedule
LIVE_TEST.md                       — Phase 1 results + Phase 2 instructions
HANDOFF.md                         — this file
src/
  IDOSStakingVesting.sol           — the new wallet
  TDEDisbursement2.sol             — sibling factory
test/
  IDOSStakingVesting.t.sol         — basic happy-path fork test
  Adversarial.t.sol                — gameability + circumvention + stuck tests
script/
  Deploy.s.sol                     — parameterised single-wallet deploy
  Live.s.sol                       — live deploy + initial fund + stake
  LiveFinish.sh                    — Phase 2 closer (T+14d)
```

---

## 10. Talking to AI from here

A good first prompt for a fresh Claude/GPT conversation:

> Read https://github.com/jaymaxlei/vestingSMV2/blob/main/HANDOFF.md and tell
> me where we are. I want to {finish Phase 2 of the live test / roll out the
> v2 factory / decide what to do about the 20,070 FCL Months 2-6 wallets}.
> Use the Etherscan API key in the handoff to read on-chain state if needed.

You can also paste this entire file directly into the chat and start asking
questions.
