// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {IERC20}              from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDOSStakingVesting, IIDOSNodeStaking} from "../src/IDOSStakingVesting.sol";

/// @notice Fork-test against Arbitrum mainnet. Verifies that the new wallet
///         can stake/unstake/withdraw against the *existing* IDOSNodeStaking
///         at 0x6132…c337, and that release() still pays the right amount
///         while tokens are staked.
///
///         Run with:
///           forge test --fork-url $ARB_RPC --fork-block-number 437400000 -vvvv
contract IDOSStakingVestingForkTest is Test {
    IERC20 constant IDOS    = IERC20(0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c);
    IIDOSNodeStaking constant STAKING =
        IIDOSNodeStaking(0x6132F2EE66deC6bdf416BDA9588D663EaCeec337);

    address constant STAKING_OWNER = 0xd5259b6E9D8a413889953a1F3195D8F8350642dE;

    address beneficiary = makeAddr("beneficiary");
    address node        = makeAddr("node");
    IDOSStakingVesting wallet;

    function setUp() public {
        // Schedule: starts now, 36 months linear (1096 days, incl. one leap
        // day — matches modality VESTED_12_36's duration), no cliff.
        uint64 start    = uint64(block.timestamp);
        uint64 duration = 1096 days;
        uint64 cliff    = 0;
        wallet = new IDOSStakingVesting(beneficiary, start, duration, cliff, IDOS, STAKING);

        // Allowlist the node (owner-gated).
        vm.prank(STAKING_OWNER);
        (bool ok,) = address(STAKING).call(abi.encodeWithSignature("allowNode(address)", node));
        require(ok, "allowNode failed");

        // Fund the wallet with 1,000,000 IDOS from the treasury.
        deal(address(IDOS), address(wallet), 1_000_000 ether);
    }

    function test_release_works_while_staked() public {
        // 1. Stake half the principal.
        vm.prank(beneficiary);
        wallet.stakeAt(node, 500_000 ether);
        assertEq(IDOS.balanceOf(address(wallet)),  500_000 ether);
        assertEq(wallet.outstandingStake(),        500_000 ether);

        // 2. Jump to ~50% of vesting period (548 days into a 1096-day vest).
        vm.warp(block.timestamp + 548 days);

        // 3. release() should account for the staked half — i.e. pay ~500k
        //    (50% of 1M), not ~250k (50% of the wallet's own 500k balance).
        wallet.release(address(IDOS));
        uint256 paid = IDOS.balanceOf(beneficiary);
        assertApproxEqRel(paid, 500_000 ether, 0.01e18);
    }

    function test_unstake_withdraw_roundtrip_keeps_accounting_solvent() public {
        vm.startPrank(beneficiary);
        wallet.stakeAt(node, 300_000 ether);
        wallet.unstakeFrom(node, 300_000 ether);
        vm.warp(block.timestamp + 14 days + 1);    // past UNSTAKE_DELAY
        uint256 returned = wallet.withdrawUnstaked();
        vm.stopPrank();

        assertEq(returned,                  300_000 ether);
        assertEq(wallet.outstandingStake(), 0);
        assertEq(IDOS.balanceOf(address(wallet)), 1_000_000 ether);
    }

    function test_only_beneficiary_can_stake() public {
        vm.expectRevert(IDOSStakingVesting.OnlyBeneficiary.selector);
        wallet.stakeAt(node, 1);
    }
}
