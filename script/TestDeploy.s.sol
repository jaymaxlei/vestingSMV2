// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import "forge-std/Script.sol";
import {IERC20}                                from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDOSStakingVesting, IIDOSNodeStaking}  from "../src/IDOSStakingVesting.sol";
contract TestDeploy is Script {
    IERC20            constant IDOS    = IERC20(0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c);
    IIDOSNodeStaking  constant STAKING = IIDOSNodeStaking(0x6132F2EE66deC6bdf416BDA9588D663EaCeec337);
    function run() external returns (IDOSStakingVesting wallet) {
        address beneficiary = vm.envAddress("TEST_BENEFICIARY");
        uint64 start    = uint64(block.timestamp);
        uint64 duration = 4 hours;
        uint64 cliff    = 0;
        vm.startBroadcast();
        wallet = new IDOSStakingVesting(beneficiary, start, duration, cliff, IDOS, STAKING);
        vm.stopBroadcast();
        console2.log("=== TEST IDOSStakingVesting deployed ===");
        console2.log("  wallet      :", address(wallet));
        console2.log("  beneficiary :", beneficiary);
        console2.log("  start       :", start);
        console2.log("  duration    :", duration);
        console2.log("  cliff       :", cliff);
    }
}
