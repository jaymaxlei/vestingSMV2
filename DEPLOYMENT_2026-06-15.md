# Deployment record — 2026-06-15

Second beneficiary wallet deployed from the same deployer EOA as the
2026-06-12 deploy. Identical contract code, identical schedule
parameters, different beneficiary.

## The wallet

| Field                        | Value                                                                  |
| ---------------------------- | ---------------------------------------------------------------------- |
| Contract                     | `IDOSStakingVesting` (commit `86c87b6` — same bytecode as the first deploy) |
| Address                      | `0x1434a476028e7eD5a8F829A6babd8D1B6Df4e870`                          |
| Network                      | Arbitrum One (chain id `42161`)                                       |
| Beneficiary / `owner()`      | `0x74d8a5492b99e78D70850229b9C0E38466dc72bD` (a smart contract — Safe / multisig) |
| `start()`                    | `1781546528`  =  2026-06-15 18:02:08 UTC                              |
| `duration()`                 | `94 694 400` s  =  1 096 days  =  36 months                           |
| `cliff()`                    | `1781546528` (= start, no effective cliff)                            |
| `end()`                      | `1876240928`  =  2029-06-15 18:02:08 UTC                              |
| `IDOS()`                     | `0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c`                          |
| `STAKING()`                  | `0x6132F2EE66deC6bdf416BDA9588D663EaCeec337`                          |
| Source verified on Arbiscan? | ✓ at <https://arbiscan.io/address/0x1434a476028e7eD5a8F829A6babd8D1B6Df4e870#code> |

### Constructor arguments

```
00000000000000000000000074d8a5492b99e78d70850229b9c0e38466dc72bd   beneficiary
000000000000000000000000000000000000000000000000000000006a303e20   startTimestamp
0000000000000000000000000000000000000000000000000000000005a4ec00   durationSeconds = 94 694 400
0000000000000000000000000000000000000000000000000000000000000000   cliffSeconds    = 0
00000000000000000000000068731d6f14b827bbcffbebb62b19daa18de1d79c   idos
0000000000000000000000006132f2ee66dec6bdf416bda9588d663eaceec337   staking
```

## Beneficiary is a contract, not an EOA

Unlike the 2026-06-12 deploy (whose beneficiary was a plain EOA), this
beneficiary is a smart contract — almost certainly a Safe / multisig given
its bytecode prefix.

Implications for the vesting wallet:

- **`release(IDOS)`** — works normally. IDOS is `safeTransfer`'d to the
  Safe address; the Safe accepts ERC20 transfers natively.
- **`release()` for ETH** — uses `Address.sendValue` which forwards all
  gas. The Safe accepts ETH via its `receive()` function. Fine.
- **Staking helpers (`stakeAt`, `unstakeFrom`, `withdrawUnstaked`,
  `withdrawReward`)** — these have the `onlyBeneficiary` modifier, so
  `msg.sender` must equal `owner()`, which is the Safe. The Safe must
  therefore execute the call (via `execTransaction` / `executeUserOp` /
  equivalent). For Gnosis Safe this is standard practice — the Safe
  signers approve a transaction that calls the vesting wallet's
  `stakeAt(...)`, the Safe executes it, the call lands with
  `msg.sender == Safe == owner()`, the modifier passes.
- **`claimVested` / `release` (permissionless)** — anyone can call,
  funds always land in `owner()` = the Safe. No additional Safe
  cooperation required.

## Deployer permissions — verified zero (identical to 2026-06-12 deploy)

| Attempted call from deployer (`0x2EBcAc…08c1`) | Live revert                             |
| ---------------------------------------------- | --------------------------------------- |
| `stakeAt(node, amount)`                        | `OnlyBeneficiary()` (`0x5e5a9749`)      |
| `unstakeFrom(node, amount)`                    | `OnlyBeneficiary()`                     |
| `withdrawUnstaked()`                           | `OnlyBeneficiary()`                     |
| `withdrawReward()`                             | `OnlyBeneficiary()`                     |
| `transferOwnership(deployer)`                  | `OwnableUnauthorizedAccount(deployer)`  |
| `renounceOwnership()`                          | `OwnableUnauthorizedAccount(deployer)`  |

## Gas accounting

| | |
| - | - |
| Deployer ETH before this deploy | 0.006642169327569716 ETH (after 2026-06-12 deploys) |
| Cost of this deploy + Arbiscan verify | 0.000031146878652000 ETH |
| **Remaining**                          | **0.006611022448917716 ETH** (98.8 % of original 0.00669 funding) |

## Schedule-vs-funding caveat (same as 2026-06-12)

The 36-month clock started at deploy time, **not at funding time**. If
IDOS is sent to the wallet some days later, time-already-elapsed counts
against the duration. This is OpenZeppelin's default behaviour, identical
to the v1 `IDOSVesting` cohort.
