#!/usr/bin/env bash
# Final step of the live IDOSStakingVesting test on Arbitrum One.
# Run this any time AFTER 14 days from the unstakeFrom() transaction
# (block 463128546, tx 0x7e53423e3b432864678d14d40aa2075fd650c7c50553bf56a4b6d6da6e849b71).
#
# It pulls the unstake-ripe 50 IDOS back into the wallet, then releases the
# remaining vested portion (~92.54 IDOS) to the beneficiary EOA.
#
# Usage:
#   PRIVATE_KEY=… ./script/LiveFinish.sh
#
# The script verifies the closing state and exits non-zero if anything is off.
set -euo pipefail

: "${PRIVATE_KEY:?PRIVATE_KEY must be set (beneficiary key)}"
RPC=${ARB_RPC:-https://arb1.arbitrum.io/rpc}

WALLET=0xbe7a0Fd150216273Ff879F25902dC2761A0d4CA6
NODE=0x0C5393db793DbA88f16DC4D030D678FBD88F8B0D
IDOS=0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c
STAKING=0x6132F2EE66deC6bdf416BDA9588D663EaCeec337
BENEFICIARY=0x1bCE6d61F2cFE40F0879b17a43780695CbCc19ff

echo "=== Pre-state ==="
echo "  wallet IDOS         : $(cast call $IDOS 'balanceOf(address)(uint256)' $WALLET --rpc-url $RPC)"
echo "  beneficiary IDOS    : $(cast call $IDOS 'balanceOf(address)(uint256)' $BENEFICIARY --rpc-url $RPC)"
echo "  outstandingStake    : $(cast call $WALLET 'outstandingStake()(uint256)' --rpc-url $RPC)"
echo "  released() ledger   : $(cast call $WALLET 'released(address)(uint256)' $IDOS --rpc-url $RPC)"

echo
echo "=== 1) withdrawUnstaked() — should now succeed (>=14 days elapsed) ==="
cast send $WALLET 'withdrawUnstaked()' --rpc-url $RPC --private-key $PRIVATE_KEY \
  | grep -E '^(status|transactionHash|blockNumber|gasUsed)'

echo
echo "=== 2) release(IDOS) — drain remaining vested portion to beneficiary ==="
cast send $WALLET 'release(address)' $IDOS --rpc-url $RPC --private-key $PRIVATE_KEY \
  | grep -E '^(status|transactionHash|blockNumber|gasUsed)'

echo
echo "=== Final state ==="
WB=$(cast call $IDOS 'balanceOf(address)(uint256)' $WALLET --rpc-url $RPC)
MB=$(cast call $IDOS 'balanceOf(address)(uint256)' $BENEFICIARY --rpc-url $RPC)
OS=$(cast call $WALLET 'outstandingStake()(uint256)' --rpc-url $RPC)
RL=$(cast call $WALLET 'released(address)(uint256)' $IDOS --rpc-url $RPC)

echo "  wallet IDOS         : $WB"
echo "  beneficiary IDOS    : $MB"
echo "  outstandingStake    : $OS"
echo "  released() ledger   : $RL"

# Expected end-state: wallet = 0, beneficiary >= 200e18 (returned to >= starting balance),
# outstandingStake = 0, released() = 100e18.
if [[ "$(cast --to-dec ${WB%% *})" == "0" \
   && "$(cast --to-dec ${OS%% *})" == "0" \
   && "$(cast --to-dec ${RL%% *})" == "100000000000000000000" ]]; then
  echo
  echo "PASS — full lifecycle complete. 100 IDOS released, nothing stuck."
else
  echo
  echo "WARN — final state did not match expected. Investigate."
  exit 1
fi
