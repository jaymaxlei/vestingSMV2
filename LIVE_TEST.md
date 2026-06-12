# Live test — Arbitrum One

Deployed and stress-tested against the canonical `IDOSNodeStaking` contract
(`0x6132F2EE66deC6bdf416BDA9588D663EaCeec337`) on 2026-05-15 with a 4-hour
linear / no-cliff schedule.

## Addresses

| Role               | Address                                        |
| ------------------ | ---------------------------------------------- |
| Vesting wallet     | `0xbe7a0Fd150216273Ff879F25902dC2761A0d4CA6`   |
| Beneficiary / EOA  | `0x1bCE6d61F2cFE40F0879b17a43780695CbCc19ff`   |
| Target node        | `0x0C5393db793DbA88f16DC4D030D678FBD88F8B0D`   |
| IDOS token         | `0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c`   |
| IDOSNodeStaking    | `0x6132F2EE66deC6bdf416BDA9588D663EaCeec337`   |

## Schedule

| Param      | Value                          |
| ---------- | ------------------------------ |
| `start`    | `1778857909` (deploy block)    |
| `duration` | `14400` s  (4 hours)           |
| `cliff`    | `0`                            |
| Funded     | 100 IDOS                       |

## Transaction log

| Step | Action                                                              | Tx hash                                                              | Result |
| ---- | ------------------------------------------------------------------- | -------------------------------------------------------------------- | ------ |
| 1    | Deploy wallet + fund 100 IDOS                                       | (deploy in Live.s.sol broadcast bundle)                              | OK |
| 2    | `stakeAt(node, 50 IDOS)`                                            | `0xf0364627274f56b6e4929cb2252ad6a6032fac5480d891d8d02d128d475131ef` | OK — 50 IDOS moved wallet → staking, `outstandingStake = 50e18`, `stakeByNodeByUser = 50e18` |
| 3    | `release(IDOS)` at T+1069s (7.42% elapsed)                          | `0x78378500fed7858bff26ab9f3ba3024214728df5e722a018a6050e1ab79cb5d4` | OK — paid **7.458 IDOS**, matching the linear schedule against the **full 100 IDOS allocation** (would have been ~3.7 IDOS if the override didn't count staked tokens) |
| 4    | `unstakeFrom(node, 50 IDOS)`                                        | `0x7e53423e3b432864678d14d40aa2075fd650c7c50553bf56a4b6d6da6e849b71` | OK — `stakeByNodeByUser → 0`, queued in `unstakesByUser` |
| 5    | `withdrawUnstaked()` immediately afterward                          | (reverted — gas-estimation revert before broadcast)                  | EXPECTED REVERT — `NoWithdrawableStake` (selector `0xf395c842`); 14-day delay enforced |

## Mid-state snapshot

```
wallet IDOS         : 42.541666666666666667
beneficiary IDOS    : 107.458333333333333333   (initial 100 + 7.458 released)
outstandingStake    : 50.000000000000000000
getUserStake.active : 0
getUserStake.slashed: 0
released(IDOS)      : 7.458333333333333333
```

## Findings

- **Stake-aware vested math works in production**, not just in fork tests:
  `vestedAmount(IDOS, T+1069s)` returned `7.4236 IDOS` — proportional to the
  full 100 IDOS principal, not the 42.54 sitting in the wallet at that moment.
- **Unstake correctly drains the per-node position** and parks tokens in the
  staking contract's pending-unstake queue.
- **14-day delay is enforced**: the staking contract reverts with
  `NoWithdrawableStake` when `withdrawUnstaked()` is called before the queue
  is ripe. Tokens are not lost — they remain reachable after the delay.

## Phase 2 verification (2026-06-12)

The unstake transaction landed at block `463128546` on 2026-05-15 15:29 UTC.
At the time of this verification (block `472696397`, `block.timestamp =
1781261583`, 2026-06-12 10:53 UTC) **27.8 days** had elapsed — well past
the 14-day `UNSTAKE_DELAY`.

### Pre-Phase-2 on-chain state

```
wallet IDOS               : 42.541666666666666667
beneficiary IDOS          : 0                       (was 107.458 right after Phase 1)
wallet outstandingStake   : 50.000000000000000000
wallet released(IDOS)     : 7.458333333333333333
wallet owner()            : 0x1bCE6d61F2cFE40F0879b17a43780695CbCc19ff
staking stakeByNodeByUser : 0
staking getUserStake      : (active=0, slashed=0)
beneficiary ETH balance   : 0 wei
beneficiary nonce         : 7   (one extra tx after Phase 1's nonce of 6 —
                                  the leaked key was used to sweep IDOS+ETH)
```

The leaked-key scraper called by the OPS-001 incident (see `AUDIT.md` §9)
has fully drained the beneficiary EOA. The vesting wallet itself is
untouched — owner was not transferred, balances exactly match where Phase 1
left them, and the staking position is correctly drained to 0 active / 0
slashed.

### Phase 2 simulation via `eth_call` (no broadcast required)

```sh
$ cast call 0xbe7a0Fd150216273Ff879F25902dC2761A0d4CA6 \
            'claimVested()(uint256,uint256)' \
            --rpc-url https://arb1.arbitrum.io/rpc
92541666666666666667 [9.254e19]          # releasedAmount  = 92.541666 IDOS
50000000000000000000 [5e19]              # unstakedReturned = 50 IDOS
```

`claimVested()` is permissionless on the deployed wallet; anyone with gas
can trigger the closeout. The simulation confirms it would return the
exact expected values and the trailing `release(IDOS)` would succeed by 0
wei margin (free balance after withdrawUnstaked == required transfer).

### Broadcasting Phase 2 in production

The beneficiary EOA has **0 ETH**, so even though the test private key still
controls `owner()`, it cannot pay gas. Two options to actually move the
tokens on-chain:

1. **Permissionless route.** Any address with ~0.0001 ETH on Arbitrum can
   call `claimVested()` on `0xbe7a0Fd1…4CA6`. The released portion lands
   in `owner()` — i.e. the leaked EOA — and will almost certainly be
   swept again by the scraper. This validates the contract logic but the
   tokens do not stay under team control.
2. **Recovery route.** From a fresh team-controlled address, fund the
   beneficiary EOA with ~0.0001 ETH, **immediately** call
   `transferOwnership(newSafeEOA)` (mempool race against the scraper),
   then run `script/LiveFinish.sh` from the new EOA. Tokens land safely.

End-state expected for either route: wallet IDOS = 0, owner-of-the-moment
holds 100 IDOS (in route 1 the scraper sweeps shortly after), `released(IDOS)
= 100e18`, `outstandingStake = 0`. Nothing stuck on-chain.

## Full adversarial suite — re-run on 2026-06-12

```
Ran 15 tests for test/Adversarial.t.sol:IDOSStakingVestingAdversarial
  test_circumvent_no_external_allowance              [PASS] (gas:  2 270 443)
  test_circumvent_only_beneficiary_can_stake_etc     [PASS] (gas:     28 122)
  test_circumvent_reentrant_owner_cannot_drain       [PASS] (gas:    323 300)
  test_circumvent_t0_nothing_leaks                   [PASS] (gas:  2 258 294)
  test_circumvent_third_party_release_pays_beneficiary [PASS] (gas:  94 561)
  test_circumvent_transfer_ownership_doesnt_unlock   [PASS] (gas:  2 344 636)
  test_constructor_rejects_zero_addresses            [PASS] (gas:    127 791)
  test_foreign_token_vests_normally                  [PASS] (gas:    572 835)
  test_game_cannot_release_more_than_schedule        [PASS] (gas:  5 251 276)
  test_game_overstake_reverts                        [PASS] (gas:  2 288 537)
  test_game_round_trips_dont_drift                   [PASS] (gas:  9 803 719)
  test_stuck_full_lifecycle_returns_everything       [PASS] (gas: 16 963 846)
  test_stuck_pause_then_unpause_recovers             [PASS] (gas:  2 187 297)
  test_stuck_premature_withdraw_does_not_lose_tokens [PASS] (gas:  2 183 585)
  test_stuck_slashing_lost_but_rest_still_releasable [PASS] (gas: 17 408 744)

Ran 3 tests for test/IDOSStakingVesting.t.sol:IDOSStakingVestingForkTest
  test_only_beneficiary_can_stake                    [PASS] (gas:     12 815)
  test_release_works_while_staked                    [PASS] (gas:  2 317 096)
  test_unstake_withdraw_roundtrip_keeps_accounting_solvent [PASS] (gas: 2 176 478)

2 suites · 18/18 passing · 882s wall (Arbitrum fork)
```
