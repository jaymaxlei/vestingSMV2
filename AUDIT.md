# Audit — `IDOSStakingVesting`

**Auditor:** Claude (Anthropic), self-audit
**Conflict of interest:** Yes. The code under review was written by the same
auditor. A third-party audit by an unaffiliated firm is strongly recommended
before any high-value or production deployment. This document is intended
as a structured pre-audit pass, not a substitute for one.
**Scope:** Commit `e76c7a9` of <https://github.com/jaymaxlei/scratch> under review:

- `src/IDOSStakingVesting.sol` (≈100 lines)
- `src/TDEDisbursement2.sol` (≈100 lines, factory)
- Indirect dependency: deployed `IDOSNodeStaking` at `0x6132F2EE…c337` (out of scope, treated as trusted)
- Indirect dependency: deployed `IDOSToken` at `0x68731d6F…d79c` (out of scope, treated as trusted)
- Indirect dependency: OpenZeppelin Contracts v5.5.0 (treated as trusted)

**Methodology:**

1. Manual line-by-line review.
2. Adversarial walkthroughs against each external function entry point.
3. State-invariant analysis for `outstandingStake`, `released`, `vestedAmount`.
4. Reentrancy traces through `release`, `claimVested`, `withdrawUnstaked`, `withdrawReward`.
5. Slashing / pause / ownership-transfer scenario analysis.
6. Compiler edge cases (overflow, timestamp wraparound, immutable layout).
7. Cross-checking against the deployed `IDOSNodeStaking` and `IDOSToken` source.

---

## 1. Executive summary

The contract is small, the design is bounded, and the trust surface is
narrow. No findings of Critical or High severity were identified. The most
important Medium and Low findings concern:

- Permission-gating consistency between `withdrawUnstaked()` and the
  permissionless `claimVested()` (intentional, but worth documenting).
- A real **usability footgun**: at end-of-schedule, if the staked principal
  has not yet been withdrawn from the staking contract, `release()` reverts
  with an ERC20 insufficient-balance error rather than partially releasing.
  No funds are lost; the user must unstake first.
- Inheritance of `Ownable.renounceOwnership()` from OZ, which if called
  would cause all future releases to burn tokens to `address(0)`.
- Reliance on a single `outstandingStake` counter plus a live read of
  `STAKING.getUserStake().slashed`, both of which assume the deployed
  staking contract behaves exactly as observed.
- Lack of contract-emitted events for the four staking helpers.

Overall verdict: **the design is sound and matches its stated invariants**,
but several quality-of-life and defensive improvements are worth merging
before a third-party audit.

| Severity | Count | What it means |
| -------- | ----- | ------------- |
| Critical | 0     | Funds at immediate risk |
| High     | 0     | Funds at risk under plausible conditions |
| Medium   | 4     | Real bug or defect; user-visible; not catastrophic |
| Low      | 5     | Hardening or correctness in edge cases |
| Informational | 9 | Design choices worth documenting; non-issues |
| Gas      | 3     | Optimization opportunities |

---

## 2. Findings

Numbering is per-severity; line references are against `src/IDOSStakingVesting.sol` at commit `e76c7a9`.

### Medium

#### M-1. `release()` reverts at end-of-schedule if any IDOS is still staked

**Location:** behavior of inherited `VestingWallet.release(address)` combined
with the override of `vestedAmount(address, uint64)` on lines 65–77.

**Description.** When a non-trivial share of the principal sits with the
staking contract at the moment `release(IDOS)` is invoked, the function may
attempt to transfer more IDOS than the wallet's free balance:

```
vestedAmount(IDOS, now) = _vestingSchedule(balance + released + alive, now)
releasable               = vestedAmount - released
                         = balance + alive   (at end of schedule)
release()                = safeTransfer(owner, releasable)
                         → reverts when alive > 0 and balance < releasable
```

Concretely, consider a 100-IDOS allocation with 50 IDOS staked at the start
and no intermediate releases. At `ts >= end`:

```
vestedAmount   = 100
released       = 0
releasable     = 100
wallet balance = 50
release() → ERC20InsufficientBalance(50, 100)
```

Funds are not lost. The beneficiary must first call `unstakeFrom(node, …)`
on every node, wait 14 days for the staking-contract `UNSTAKE_DELAY`, call
`withdrawUnstaked()` to pull the principal back, and then `release(IDOS)`.
`claimVested()` automates the withdraw-and-release piece but still requires
the prior `unstakeFrom` call and wait.

**Severity:** Medium. Funds are recoverable, but the user-facing failure
mode (a revert with no contract-defined error) is unintuitive and likely to
generate support tickets.

**Recommended remediation.** Either:

- (a) Override `release(address)` to cap the transfer at the free balance
  and proportionally adjust `_erc20Released[token]`. Note that
  `_erc20Released` is `private` in OZ v5; this requires shadowing the
  released-amount accounting in the child contract and overriding
  `released(token)` to return the shadow. ~25 lines of code, modest
  complexity.
- (b) Add a `requiredUnstakeFor(uint256 releaseAmount)` helper view and a
  dedicated front-end / docs flow that surfaces "unstake before release at
  end of schedule".
- (c) Document the constraint clearly in the README and consider adding a
  custom error so the revert message is at least self-explanatory.

Option (a) is the most robust but trades against contract complexity. (c)
is the lowest-cost mitigation.

---

#### M-2. `claimVested()` is permissionless yet bypasses the `onlyBeneficiary`
guard on `withdrawUnstaked()`

**Location:** lines 99–110 (`claimVested`) vs. lines 90–96 (`withdrawUnstaked`).

**Description.** `withdrawUnstaked()` is gated to the beneficiary
(`onlyBeneficiary`), but `claimVested()` is `external` (no modifier) and
internally calls `STAKING.withdrawUnstaked()` directly, so any address can
effectively trigger the withdraw side-effect by going through
`claimVested()`.

This is intentional — every code path in `claimVested()` is
beneficiary-favourable (matured unstakes land in the wallet, vested IDOS
goes to the beneficiary EOA) and the caller pays the gas. But the
asymmetric gating is the kind of thing a third-party auditor will flag as
"non-obvious privilege model" if not addressed.

**Severity:** Medium (intentional, but inconsistent surface).

**Recommended remediation.** Either:

- (a) Remove `onlyBeneficiary` from `withdrawUnstaked()` and document both
  functions as permissionless. (My preferred fix — it just matches reality.)
- (b) Add a `bool requireBeneficiary` parameter to `claimVested()`.
- (c) Document the asymmetry explicitly in NatSpec.

---

#### M-3. Inherited `renounceOwnership()` can burn locked IDOS

**Location:** inherited from `Ownable` via `VestingWallet`.

**Description.** OZ's `Ownable.renounceOwnership()` is `public onlyOwner`
and sets `owner()` to `address(0)`. After that, any subsequent
`release(IDOS)` call sends the vested amount to `address(0)`, which is a
permanent burn. Since `release()` is permissionless, an attacker who knew
about a renounced wallet could front-run the timer and burn the entire
allocation transaction-by-transaction.

The same footgun exists on the v1 `IDOSVesting` and is therefore inherited
by convention rather than introduced here. But it remains a one-keystroke
catastrophe for the beneficiary.

**Severity:** Medium (low likelihood, high impact, one-line fix).

**Recommended remediation.** Override and revert:

```solidity
function renounceOwnership() public view override onlyOwner {
    revert("renounceOwnership disabled");
}
```

If a deliberate forfeit feature is desired in the future, replace with an
explicit `forfeitTo(address sink)` that pays out remaining IDOS to a
specified non-zero address.

---

#### M-4. Slashing breaks vestedAmount monotonicity

**Location:** lines 65–77 (`vestedAmount`).

**Description.** OZ's `VestingWallet` documents `vestedAmount(token, ts)` as
a monotonically non-decreasing function of `ts`. With slashing in the
picture, this is no longer true here: a slash event between two reads at
the same `ts` (or even at strictly increasing `ts` if `_vestingSchedule`
gain is smaller than the slashing loss) can make `vestedAmount` return a
smaller value than it did before.

The clamp `Math.max(_vestingSchedule(total, ts), alreadyReleased)` ensures
this can never cause `releasable()` to underflow — that is the explicit
bug it fixes. But off-chain consumers (UIs, indexers, subgraph code) that
assume monotonicity will be confused or buggy.

**Severity:** Medium (correctness of integrations, not the contract itself).

**Recommended remediation.** Document explicitly that monotonicity is broken
by slashing. Optionally, expose a `slashedSnapshot()` view that returns the
current `STAKING.getUserStake(this).slashed` so indexers can detect the
discontinuity directly.

---

### Low

#### L-1. Inconsistent computation of "tokens returned" between
`withdrawUnstaked()` and `claimVested()`

**Location:** line 91 (`withdrawUnstaked` uses balance-delta) vs. line 100
(`claimVested` uses staking's return value).

**Description.** Two paths compute the same quantity differently:

```solidity
// withdrawUnstaked
uint256 before = IDOS.balanceOf(address(this));
STAKING.withdrawUnstaked();
received = IDOS.balanceOf(address(this)) - before;
outstandingStake -= received;

// claimVested
try STAKING.withdrawUnstaked() returns (uint256 r) {
    unstakedReturned = r;
    outstandingStake -= r;
} catch { … }
```

Both produce the same number for a well-behaved IDOS token, but the
balance-delta version is mildly more defensive (it would catch a future
upgrade of IDOS to a fee-on-transfer or rebasing token, hypothetical though
that is for a deployed immutable contract).

**Severity:** Low (cosmetic; consistency only).

**Recommended remediation.** Harmonise both paths to the balance-delta
pattern.

---

#### L-2. No contract-emitted events for staking actions

**Location:** functions `stakeAt`, `unstakeFrom`, `withdrawUnstaked`,
`withdrawReward`, `claimVested`.

**Description.** Each of these triggers events on the staking contract but
emits nothing local. For an indexer following a single beneficiary across
many wallets, having a wallet-level event surface is more convenient than
joining staking events to wallet addresses.

**Severity:** Low.

**Recommended remediation.** Add events:

```solidity
event Staked(address indexed node, uint256 amount);
event Unstaked(address indexed node, uint256 amount);
event UnstakeWithdrawn(uint256 amount);
event RewardWithdrawn(uint256 amount);
event Claimed(uint256 releasedAmount, uint256 unstakedReturned);
```

---

#### L-3. Floating-pragma allows future minor versions to be used

**Location:** line 2 (`pragma solidity ^0.8.27;`).

**Description.** The pragma matches any `>=0.8.27, <0.9.0`. While the
audit and live tests were performed with `0.8.28`, future minor versions
introduce subtle codegen and ABI changes (e.g., transient storage, new
yul intrinsics) that have surprised projects in the past.

**Severity:** Low.

**Recommended remediation.** Pin to the exact compiler version used in
production: `pragma solidity 0.8.28;`.

---

#### L-4. `transferOwnership` is single-step (OZ `Ownable`, not
`Ownable2Step`)

**Location:** inherited from OZ.

**Description.** A mistyped recipient becomes the new beneficiary
immediately and irreversibly. If the address is not controlled by anyone,
all remaining IDOS vests to a dead address.

**Severity:** Low.

**Recommended remediation.** Switch to `Ownable2Step` for `IDOSStakingVesting`.
Beneficiaries set in the constructor are unaffected; only post-deploy
transfers gain a confirmation step. Trade-off: extra tx, slightly more
inheritance surface.

---

#### L-5. Constructor does not validate `cliff <= duration` for the case
`cliff = 0` interaction with `start = 0`

**Location:** constructor on lines 41–58.

**Description.** `VestingWalletCliff` does validate `cliff <= duration`,
but it does not validate that `start > 0` or that the resulting schedule
is sensible (e.g., `start` far in the past with `duration` very short
results in `vestedAmount == total` immediately, which is allowed but may
not be intended). The factory `TDEDisbursement2` is the gatekeeper for
"sensible" parameters today; a direct deployer of `IDOSStakingVesting`
gets no validation.

**Severity:** Low (operational, mitigated by factory).

**Recommended remediation.** Add `require(duration > 0)` and optionally
`require(start >= block.timestamp - SOME_BACKDATE_LIMIT)` if backdating
should be bounded.

---

### Informational

#### I-1. Rewards vest with principal

**Location:** `withdrawReward()` (lines 88–90).

By design, staking rewards land in the wallet and are subject to the same
vesting schedule. This is documented but worth re-stating: a beneficiary
who expects rewards to be immediately spendable will be surprised. An
alternative variant (rewards-pass-through) is sketched in `README.md`.

#### I-2. No emergency pause / circuit breaker

`IDOSStakingVesting` has no pause function. This is consistent with the
"irrevocable vesting wallet" model — and consistent with v1 — but it means
that if a critical bug were ever found post-deploy, the only available
mitigations are off-chain (e.g., asking the beneficiary to `transferOwnership`
to a recovery contract).

#### I-3. Reliance on `STAKING.getUserStake().slashed` for slashing accounting

The wallet trusts the staking contract to report its slashed amount
honestly and consistently. A bug there propagates into `vestedAmount`.

#### I-4. Reliance on the immutable `STAKING` and `IDOS` addresses

Both are set in the constructor and cannot be updated. If either contract
were ever migrated to a new address, the wallet cannot follow.

#### I-5. `forceApprove` instead of `approve`

Marginally more defensive for non-standard ERC20s, slightly more gas. IDOS
is plain ERC20, so the defense is unused.

#### I-6. ETH `receive()` inherited from `VestingWallet`

The wallet accepts ETH and treats it as vesting principal under the same
schedule. Send-by-mistake is recoverable via `release()` (the no-arg ETH
variant). Not a bug, but worth noting in beneficiary documentation.

#### I-7. Foreign ERC20s vest on the same schedule

Any ERC20 sent to the wallet by mistake will vest on the IDOS schedule via
OZ default behaviour. Recoverable via `release(otherToken)`.

#### I-8. `uint64` timestamps

End-of-time for the schedule is in year 5.8e11. Not a concern.

#### I-9. Block-timestamp manipulation

Validators can move `block.timestamp` by a small amount. Over a 36-month
schedule the effect is sub-percent. Not exploitable.

---

### Gas

#### G-1. `forceApprove` performs two SSTOREs

`approve` would do one (after the staking contract consumes the allowance,
which resets it to 0). For a beneficiary that stakes/unstakes many times,
this is ~5k gas per stake. Switch unless the defensive posture is valued.

#### G-2. `outstandingStake` is read twice in `vestedAmount` when `token == IDOS`

Compiler should optimise but explicit caching to a local is cheaper to
reason about.

#### G-3. `getUserStake` is called from a view (`vestedAmount`) and iterates
the slashed-nodes set inside `IDOSNodeStaking`

`release()` is non-view and pays this cost. As the global slashed-nodes
set grows, so does the gas cost of every `release()`. This is an external
contract issue but worth tracking.

---

## 3. Adversarial scenarios checked

### "Can the beneficiary extract more than scheduled?"

For any sequence of operations $S$:

$$
\text{released}(S) \le \max_{t \in S} \text{vestedAmount}(t)
$$

This follows from OZ's `release`:

```
amount = releasable                  = vestedAmount(now) - released
_erc20Released[token] += amount      // always updates BEFORE the transfer
safeTransfer(owner, amount)          // reverts cancel both the storage write and event
```

So `released` is monotonically non-decreasing in time and bounded above by
the maximum `vestedAmount` ever returned. Our `vestedAmount` is in turn
bounded above by `_vestingSchedule(total, ts)` which, in the linear OZ
implementation, is bounded above by `total`. Hence:

```
released ≤ vestedAmount ≤ total = balance + released + alive
```

so `released ≤ balance + alive`. Since `alive` is itself recoverable to
balance only via the unstake/withdraw path, the beneficiary can never
hold more than the original total minus slashing.

**Verified via fork tests** in `test/Adversarial.t.sol`:
`test_game_cannot_release_more_than_schedule` (8x rapid stake/unstake cycles)
and `test_game_round_trips_dont_drift`.

### "Can vesting be circumvented before the schedule allows?"

Six entry points were examined: `release` (permissionless, but pays only
`releasable`), `claimVested` (permissionless, same), `stakeAt`,
`unstakeFrom`, `withdrawUnstaked`, `withdrawReward` (all `onlyBeneficiary`),
and `transferOwnership` (only-owner; new owner is still bound by the
schedule). No path produces a beneficiary EOA balance exceeding the
time-vested amount.

**Verified via fork tests:** `test_circumvent_t0_nothing_leaks`,
`test_circumvent_only_beneficiary_can_stake_etc`,
`test_circumvent_third_party_release_pays_beneficiary`,
`test_circumvent_no_external_allowance`,
`test_circumvent_transfer_ownership_doesnt_unlock`,
`test_circumvent_reentrant_owner_cannot_drain`.

### "Can tokens be permanently stuck in the staking contract?"

Three risks:

1. **Pre-delay withdraw.** `withdrawUnstaked()` reverts with
   `NoWithdrawableStake`; queue and timestamps are preserved. Tokens
   become withdrawable when ≥14 days have elapsed. ✓ verified live on
   Arbitrum (tx `0x7e53…9b71`).
2. **Slashing.** Slashed tokens are by-design lost to the staking contract
   owner. The remaining stake at non-slashed nodes is fully recoverable.
   ✓ verified by `test_stuck_slashing_lost_but_rest_releasable`.
3. **Pause.** While the staking contract is paused, `unstake` /
   `withdrawUnstaked` revert (and so do `stake` calls). Tokens are not
   lost; the queue resumes on `unpause`. ✓ verified by
   `test_stuck_pause_then_unpause_recovers`.

### "Reentrancy"

The contract has no reentrancy guards. None are necessary because:

1. `IDOS` is plain ERC20 (no transfer hooks).
2. `IDOSNodeStaking` carries `nonReentrant` on every state-changing
   external function.
3. OZ `release` updates `_erc20Released[token]` strictly before
   `safeTransfer`, so a re-entrant `release` reads the updated `released`
   and computes `releasable = 0`.
4. The only callback surface in `release` is the receiving owner's
   `receive()` or fallback. A malicious owner contract was tested via
   `test_circumvent_reentrant_owner_cannot_drain` and cannot extract more
   than scheduled.

### "Front-running"

`release()` is permissionless. A third party calling `release()` ahead of
the beneficiary just pays the gas for them — the destination is fixed.
Spam-calling `release()` is uneconomic (after the first call,
`releasable = 0` and subsequent calls are no-ops at full gas cost). No
exploit.

### "Slashing accounting edge cases"

For a wallet with stakes at nodes $A$ (slashed) and $B$ (safe), and
arbitrary stake / unstake operations, the invariant

$$
\text{alive} = \text{outstandingStake} - \text{slashed}
$$

equals the sum of (a) still-active stake at non-slashed nodes and
(b) tokens in the unstake queue. The case "stake at a node, fully unstake,
then the node is slashed" correctly contributes 0 to `slashed` because the
beneficiary's `stakeByNodeByUser[wallet][node]` is already 0. The case
"stake at a node, slash, attempt to unstake" reverts inside the staking
contract (`NodeIsSlashed`); the tokens are accounted as lost via
`alive = 0` and `vestedAmount` reduces accordingly.

---

## 4. State-invariant analysis

Let $P$ be the total IDOS ever transferred into the wallet (principal +
externally-funded reward top-ups). Let $R$ be the total ever released to
the owner, $W$ the total ever withdrawn back from the unstake queue, and
$U$ the total ever sent to staking via `stakeAt`. Let $S$ be the current
`STAKING.getUserStake(this).slashed`.

Then at all times:

| Invariant | Holds because |
| --------- | ------------- |
| `outstandingStake = U − W` | Only `stakeAt` and `withdrawUnstaked` mutate it; in matching directions. |
| `IDOS.balanceOf(this) ≈ P − R − U + W + rewards` | All IDOS movements are accounted for. Rewards add to balance and are not tracked in `outstandingStake`. |
| `released(IDOS) = R` | OZ's `_erc20Released[IDOS]` accumulator. |
| `vestedAmount(IDOS, now) ≥ released(IDOS)` | Enforced by the `Math.max(..., released)` clamp. |
| `alive ≥ 0` | Enforced by the `outstandingStake > slashed ? … : 0` ternary. |

The most fragile invariant is the second one: any path that mutates
`balanceOf(this)` without corresponding bookkeeping changes the relation.
Such paths exist (anyone can `IDOS.transfer(walletAddress, x)` from the
outside) but they are *additive* — extra IDOS sent in just becomes part of
the vested allocation. There is no path that decreases `balanceOf(this)`
without going through `release` (which increments `released`) or `stakeAt`
(which increments `outstandingStake`).

---

## 5. Test coverage assessment

Existing suites: `test/IDOSStakingVesting.t.sol` (happy path) and
`test/Adversarial.t.sol` (12 adversarial cases). Coverage is excellent on
the primary risk vectors. Gaps worth filling:

1. **End-of-schedule release with non-trivial outstanding stake** — see
   M-1; would catch the usability footgun in CI rather than in production.
2. **`renounceOwnership` semantics** — assert that release-to-zero is
   either possible (current state) or reverts (after remediation).
3. **Rewards arriving mid-flight** — `withdrawReward` followed by a
   release at exact mid-schedule; assert beneficiary receives
   `(principal + reward) * 0.5`.
4. **Pre-cliff staking** — verify that staking works during the cliff
   window and that release still returns 0.
5. **Boundary-exact timestamps** — `ts == start`, `ts == cliff`, `ts == end`.
6. **Multi-node fan-out with mixed slashing** — stake at 5 nodes, slash 2,
   unstake from a third; check `alive` math against the expected total.
7. **Foreign ERC20 with non-trivial transfer semantics** — fee-on-transfer
   mock; assert no accounting drift on `release(foreignToken)`.

---

## 6. Integration and operational risks

These are not contract bugs but should be tracked separately:

1. **Staking-contract upgrade.** `IDOSNodeStaking` is not a proxy today.
   If it is ever migrated, `IDOSStakingVesting` wallets cannot follow and
   are effectively staking-disabled (though release continues to work for
   the free balance).
2. **Staking-contract owner powers.** The staking owner can pause,
   slash, and configure rewards. A malicious or compromised owner can
   freeze withdrawals or zero a beneficiary's stake. This is a trust
   assumption inherited from the staking contract design.
3. **Allowlist policy on staking.** Beneficiaries can only stake to
   allowlisted nodes. If the staking owner removes all nodes, beneficiaries
   can still `unstakeFrom` (the function does not check the allowlist)
   and `withdrawUnstaked`. No tokens get stuck on policy change.
4. **Front-end dependence.** Phase-2 of the live test on 2026-05-29
   onwards requires a fresh EOA after the test private key was
   compromised. Until ownership of the test wallet is transferred, that
   wallet's remaining IDOS is at risk to any GitHub-scraping bot that
   captured the leaked key.

---

## 7. Suggested remediation plan (priority order)

| Priority | Action | Severity |
| -------- | ------ | -------- |
| 1 | Override `renounceOwnership` to revert (one line). | M-3 |
| 2 | Pin compiler pragma to `0.8.28`. | L-3 |
| 3 | Add events for the four staking helpers. | L-2 |
| 4 | Add a documented `unstakeForRelease(uint256 amount)` helper (no-op if amount already unstaked) and a docs section on the unstake-before-final-release flow. | M-1 |
| 5 | Harmonise `received` computation in `withdrawUnstaked` and `claimVested` on the balance-delta pattern. | L-1 |
| 6 | Remove `onlyBeneficiary` from `withdrawUnstaked` (or relax it to allow staking-owner). | M-2 |
| 7 | Switch to `Ownable2Step`. | L-4 |
| 8 | Add the missing tests from §5. | — |
| 9 | Engage a third-party audit firm before any production-scale deployment. | — |

None of items 1–7 require changes to the deployed `IDOSNodeStaking` or
`IDOSToken`. None changes the contract's external invariants. Items 1, 2,
3, 5, 7 are <30 lines total.

---

## 8. Conclusion

`IDOSStakingVesting` is a small, focused contract that adds a single
capability (delegating locked IDOS into the canonical staking contract)
to OpenZeppelin's `VestingWallet + VestingWalletCliff`. The vesting
accounting override is correct under the documented assumptions and is
hardened against the most plausible adversarial scenarios, including
slashing-induced underflow. No paths were found that allow the
beneficiary to extract more than the schedule permits, that allow a
third party to redirect funds, or that cause tokens to be permanently
stuck beyond the by-design slashing loss.

The most consequential remaining item is **M-3 (renounce-ownership burn)**,
which is a one-line fix and should be merged before any further
production deployment. The next most consequential is **M-1 (release
revert at end-of-schedule)**, which is a usability issue and not a
correctness one, but is the kind of issue that generates user trust
incidents at scale.

A third-party audit is strongly recommended before deploying replacement
wallets for the 20,070 affected FCL Months 2-6 recipients or for any
high-value cohort.

— end of audit —
