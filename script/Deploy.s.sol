// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {IERC20}                                from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDOSStakingVesting, IIDOSNodeStaking}  from "../src/IDOSStakingVesting.sol";

/// @notice Deploys a single IDOSStakingVesting wallet on Arbitrum with a
///         36-month linear schedule and no cliff. Designed for the "specific
///         contract" the issuer wants to set up — funding is a separate
///         IDOS.transfer once the wallet address is known.
///
/// Usage:
///   BENEFICIARY=0x… \
///   START=1747353600           # optional; defaults to block.timestamp
///   PRIVATE_KEY=0x… \
///   forge script script/Deploy.s.sol --rpc-url $ARB_RPC --broadcast --verify
contract Deploy is Script {
    IERC20            constant IDOS    = IERC20(0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c);
    IIDOSNodeStaking  constant STAKING =
        IIDOSNodeStaking(0x6132F2EE66deC6bdf416BDA9588D663EaCeec337);

    /// 1096 days = 36 months including one leap day; matches the duration
    /// of the existing TDEDisbursement modality VESTED_12_36.
    uint64 constant DURATION_36M = 1096 days;
    uint64 constant CLIFF_NONE   = 0;

    function run() external returns (IDOSStakingVesting wallet) {
        address beneficiary  = vm.envAddress("BENEFICIARY");
        uint64  startCandidate = uint64(vm.envOr("START", uint256(block.timestamp)));

        vm.startBroadcast();
        wallet = new IDOSStakingVesting(
            beneficiary,
            startCandidate,
            DURATION_36M,
            CLIFF_NONE,
            IDOS,
            STAKING
        );
        vm.stopBroadcast();

        console2.log("IDOSStakingVesting deployed at:", address(wallet));
        console2.log("  beneficiary :", beneficiary);
        console2.log("  start       :", startCandidate);
        console2.log("  duration    :", DURATION_36M, "(1096 days = 36 months)");
        console2.log("  cliff       :", CLIFF_NONE, "(none)");
        console2.log("  idos        :", address(IDOS));
        console2.log("  staking     :", address(STAKING));
    }
}
