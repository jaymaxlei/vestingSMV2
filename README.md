# IDOS Staking-Aware Vesting

A vesting wallet for IDOS that lets the beneficiary delegate the **locked**
balance into the canonical `IDOSNodeStaking` contract
(`0x6132F2EE66deC6bdf416BDA9588D663EaCeec337`), without altering the staking
contract or breaking the vesting schedule.

## Why

The deployed `IDOSVesting` is plain OpenZeppelin `VestingWallet + VestingWalletCliff`.
It has no `approve`, no generic `call`, and the IDOS token has no `ERC20Votes`
or `ERC1363` hooks. There is no on-chain path from a vesting wallet into the
staking contract, so locked tokens are completely inert until released.

## What changes

- **`src/IDOSStakingVesting.sol`** — new wallet contract.
- **`src/TDEDisbursement2.sol`** — sibling factory; CREATE2 with a new salt
  namespace so addresses don't collide with v1 deployments.

**Nothing else changes.** `IDOSNodeStaking` and `IDOSToken` are untouched.

## How `vestedAmount()` stays correct

`vestedAmount(token, ts)` is overridden to include `outstandingStake` (tokens
out at staking) minus any slashed amount queried live from
`STAKING.getUserStake(this)`. So:

- While tokens are staked, `release()` still pays the right amount.
- Slashing reduces the beneficiary's effective allocation rather than bricking
  the wallet.

## Compatibility with the deployed staking contract

| Staking action                               | Why it works unchanged                                   |
| -------------------------------------------- | -------------------------------------------------------- |
| `stake(user, node, amount)`                  | Wallet calls `forceApprove(staking, amount)` first, passes `user = address(this)` |
| `unstake(node, amount)` (keyed on `msg.sender`) | Wallet is the registered staker — identity matches    |
| `withdrawUnstaked()` (sends to `msg.sender`) | Tokens come back into the wallet, not the EOA            |
| `withdrawReward()` (sends to `msg.sender`)   | Rewards land in the wallet and vest with principal       |

## Tests

```
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts
ARB_RPC=https://arb1.arbitrum.io/rpc \
  forge test --fork-url $ARB_RPC -vvvv
```

The fork test:

1. Deploys a fresh wallet with a 6-month / no-cliff schedule.
2. Pranks `STAKING_OWNER` to `allowNode(node)`.
3. Stakes half the principal, fast-forwards to mid-vesting.
4. Asserts that `release()` pays ~50% of the *full* allocation (1M),
   not ~50% of the wallet's residual balance (500k).
5. Verifies the unstake → 14-day delay → withdraw round-trip.

## Migration

Existing wallets cannot be upgraded (no proxy, no admin). New issuances go
through `TDEDisbursement2`. For long-vest users in modality 8/9, the only
practical fix is off-chain: treasury issues additional IDOS into a new
`IDOSStakingVesting`, or the beneficiary `transferOwnership()` to an escrow
that re-deposits releases into a staking-aware wallet (does not shorten
lockups).
