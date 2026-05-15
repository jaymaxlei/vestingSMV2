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

## Remaining step (T+14 days)

The unstake transaction landed at block `463128546` on 2026-05-15.  After
14 days the queue becomes ripe and:

```sh
PRIVATE_KEY=… ./script/LiveFinish.sh
```

will:

1. Call `withdrawUnstaked()` — pulls 50 IDOS back into the wallet.
2. Call `release(IDOS)` — pays the remaining ~92.54 IDOS to the beneficiary.

End-state expected: wallet IDOS = 0, beneficiary IDOS = 200 IDOS (back to its
pre-test holding), `released(IDOS) = 100e18`, `outstandingStake = 0`. Nothing
stuck.

A scheduled task has also been registered locally to fire this automatically.
