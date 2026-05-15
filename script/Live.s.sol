// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {IERC20}                                from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDOSStakingVesting, IIDOSNodeStaking}  from "../src/IDOSStakingVesting.sol";

/// @notice One-shot live deploy + initial setup script on Arbitrum.
///         Deploys a wallet with a 4-hour / no-cliff schedule, transfers
///         100 IDOS into it, stakes 50, and records the addresses to stdout
///         so the follow-up steps can target them.
contract LiveDeploy is Script {
    IERC20            constant IDOS    = IERC20(0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c);
    IIDOSNodeStaking  constant STAKING =
        IIDOSNodeStaking(0x6132F2EE66deC6bdf416BDA9588D663EaCeec337);

    // Already-allowlisted node on the live staking contract.
    address constant NODE = 0x0C5393db793DbA88f16DC4D030D678FBD88F8B0D;

    function run() external returns (IDOSStakingVesting wallet) {
        address beneficiary = vm.envAddress("BENEFICIARY");
        uint256 fundAmount  = vm.envOr("FUND_AMOUNT",  uint256(100 ether));
        uint256 stakeAmount = vm.envOr("STAKE_AMOUNT", uint256( 50 ether));

        uint64 start    = uint64(block.timestamp);
        uint64 duration = 4 hours;
        uint64 cliff    = 0;

        vm.startBroadcast();
        wallet = new IDOSStakingVesting(beneficiary, start, duration, cliff, IDOS, STAKING);
        IDOS.transfer(address(wallet), fundAmount);
        vm.stopBroadcast();

        console2.log("=== IDOSStakingVesting deployed ===");
        console2.log("  wallet         :", address(wallet));
        console2.log("  beneficiary    :", beneficiary);
        console2.log("  start (unix)   :", start);
        console2.log("  duration (s)   :", duration);
        console2.log("  cliff (s)      :", cliff);
        console2.log("  funded with    :", fundAmount);
        console2.log("  target node    :", NODE);
        console2.log("  stake amount   :", stakeAmount);
    }
}
