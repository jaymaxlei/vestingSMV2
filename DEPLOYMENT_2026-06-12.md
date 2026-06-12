# Deployment record — 2026-06-12

## Final beneficiary wallet

| Field                        | Value                                                                  |
| ---------------------------- | ---------------------------------------------------------------------- |
| Contract                     | `IDOSStakingVesting` (commit `86c87b6` — post-remediation, post-audit) |
| Address                      | `0x279b0d9066Ba4f19Ac8a9ADFB8bf93588d76746e`                          |
| Network                      | Arbitrum One (chain id `42161`)                                       |
| Beneficiary / `owner()`      | `0xE23c893c2a79788610e4c939A67B839F5E8AC9e9`                          |
| `start()`                    | `1781264390`  =  2026-06-12 11:39:50 UTC                              |
| `duration()`                 | `94 694 400` s  =  1 096 days  =  36 months                           |
| `cliff()`                    | `1781264390`  (= start, i.e. no effective cliff)                      |
| `end()`                      | `1875958790`  =  2029-06-12 11:39:50 UTC                              |
| `IDOS()`                     | `0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c`                          |
| `STAKING()`                  | `0x6132F2EE66deC6bdf416BDA9588D663EaCeec337`                          |
| Source verified on Arbiscan? | ✓ at <https://arbiscan.io/address/0x279b0d9066Ba4f19Ac8a9ADFB8bf93588d76746e#code> |

### Constructor arguments (hex-encoded as Etherscan stores them)

```
000000000000000000000000e23c893c2a79788610e4c939a67b839f5e8ac9e9   beneficiary
000000000000000000000000000000000000000000000000000000006a2bf006   startTimestamp
0000000000000000000000000000000000000000000000000000000005a4ec00   durationSeconds = 94 694 400
0000000000000000000000000000000000000000000000000000000000000000   cliffSeconds    = 0
00000000000000000000000068731d6f14b827bbcffbebb62b19daa18de1d79c   idos
0000000000000000000000006132f2ee66dec6bdf416bda9588d663eaceec337   staking
```

### Deployer permissions — verified zero

The deploying EOA `0x2EBcAc41eB798Fb71291c83c32286fD353F108c1` retains **no
on-chain ability to influence this contract** after the deploy tx mined.
Verified by direct `cast call --from <deployer>` against the live contract:

| Attempted call                       | Live revert                                                                                          |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| `stakeAt(node, amount)`              | `OnlyBeneficiary()` (selector `0x5e5a9749`)                                                          |
| `unstakeFrom(node, amount)`          | `OnlyBeneficiary()`                                                                                  |
| `withdrawUnstaked()`                 | `OnlyBeneficiary()`                                                                                  |
| `withdrawReward()`                   | `OnlyBeneficiary()`                                                                                  |
| `transferOwnership(deployer)`        | `OwnableUnauthorizedAccount(deployer)` (selector `0x118cdaa7`)                                       |
| `renounceOwnership()`                | `OwnableUnauthorizedAccount(deployer)` — and even if deployer were owner, the override would fire `RenounceOwnershipDisabled()` (M-3 fix) |
| `release(IDOS)` (permissionless)     | Allowed, but the IDOS goes to `owner()` (the beneficiary). No way to redirect.                       |
| `claimVested()` (permissionless)     | Allowed, same destination.                                                                            |

The deployer's only relationship to the contract is having paid the deploy
gas. There is no upgrade path, no admin role, no proxy.

## Pre-flight smoke test wallet

A throwaway wallet was deployed first to validate the path before the
final beneficiary deploy:

| Field          | Value                                                                  |
| -------------- | ---------------------------------------------------------------------- |
| Address        | `0xf115a9ee3d60590dfe26fedac43d313df5ddd986`                          |
| Beneficiary    | `0x2EBcAc41eB798Fb71291c83c32286fD353F108c1` (the deployer itself, intentional for the smoke test) |
| Duration       | 4 hours                                                                |
| Purpose        | Validate constructor wiring, permission gates, and M-3 renounce-revert behaviour on the actual mainnet bytecode before risking the real deploy. |

Both deploys used the same compiled artifact (`out/IDOSStakingVesting.sol/IDOSStakingVesting.json` at commit `86c87b6`).

## Gas accounting

| | |
| - | - |
| Initial deployer balance              | 0.006694326398969716 ETH |
| Cost of test deploy                    | 0.000026293331400000 ETH |
| Cost of final deploy + Arbiscan verify | 0.000025863740000000 ETH |
| Remaining after both                   | **0.006642169327569716 ETH** (≈ 99.3 % retained) |

Verifying the source on Arbiscan was free; only the deploy transaction
itself burned gas.

## Funding the wallet

The wallet is currently empty. Whoever sends IDOS to
`0x279b0d9066Ba4f19Ac8a9ADFB8bf93588d76746e` will trigger the vesting
schedule on those tokens. The schedule started at deploy time; **time
already elapsed counts against the 36-month duration whether or not the
wallet is funded yet**, by the same OpenZeppelin convention that v1
`IDOSVesting` uses.

If you'd prefer the schedule to start at the moment of funding (not at
deploy time), the wallet would need to be re-deployed with a future
`startTimestamp`. Not done in this deploy.
