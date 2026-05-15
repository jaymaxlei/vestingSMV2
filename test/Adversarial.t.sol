// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {IERC20}                              from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20}                               from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDOSStakingVesting, IIDOSNodeStaking} from "../src/IDOSStakingVesting.sol";

/// Extended interface — only the bits we need to drive the deployed staking
/// contract during tests (owner-gated allowNode/slash/pause + a couple of
/// state queries). The production wallet contract does NOT depend on these.
interface IIDOSNodeStakingFull is IIDOSNodeStaking {
    function allowNode(address node) external;
    function slash(address node) external;
    function pause() external;
    function unpause() external;
    function setEpochReward(uint256 newReward) external;
    function stakeByNodeByUser(address user, address node) external view returns (uint256);
    function stakedByEpoch(uint48 epoch) external view returns (uint256);
    function currentEpoch() external view returns (uint48);
}

/// Minimal ERC20 to test "random foreign token sent to vesting wallet".
contract DummyToken is ERC20 {
    constructor() ERC20("Dummy", "DMY") { _mint(msg.sender, 1_000_000 ether); }
}

/// Reentrant beneficiary — its fallback tries to call back into the vesting
/// wallet. Used to verify no reentrancy can pull more than the vested amount.
contract ReentrantBeneficiary {
    IDOSStakingVesting public wallet;
    bool public attacked;

    function setWallet(IDOSStakingVesting w) external { wallet = w; }

    receive() external payable {
        if (attacked || address(wallet) == address(0)) return;
        attacked = true;
        // Try to reenter every state-changing path. None of these should
        // succeed in extracting more than the legitimately-vested amount.
        try wallet.release(address(wallet.IDOS())) {} catch {}
        try wallet.claimVested() {} catch {}
        try wallet.stakeAt(address(0xdead), 1) {} catch {}
    }
}

contract IDOSStakingVestingAdversarial is Test {
    IERC20 constant IDOS = IERC20(0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c);
    IIDOSNodeStakingFull constant STAKING =
        IIDOSNodeStakingFull(0x6132F2EE66deC6bdf416BDA9588D663EaCeec337);
    address constant STAKING_OWNER = 0xd5259b6E9D8a413889953a1F3195D8F8350642dE;

    address beneficiary = makeAddr("beneficiary");
    address attacker    = makeAddr("attacker");
    address nodeA       = makeAddr("nodeA");
    address nodeB       = makeAddr("nodeB");

    IDOSStakingVesting wallet;

    uint64 vStart;
    uint64 vDuration;
    uint256 constant PRINCIPAL = 1_000_000 ether;

    function setUp() public {
        vStart    = uint64(block.timestamp);
        vDuration = 1096 days;
        wallet = new IDOSStakingVesting(
            beneficiary, vStart, vDuration, 0, IDOS, STAKING
        );

        // Allowlist both nodes (owner-gated on staking).
        vm.startPrank(STAKING_OWNER);
        STAKING.allowNode(nodeA);
        STAKING.allowNode(nodeB);
        vm.stopPrank();

        deal(address(IDOS), address(wallet), PRINCIPAL);
    }

    // ─────────────────────────────────────────────────────────────────
    // Q1.  Can it be GAMED?
    //      i.e. can the beneficiary, via any stake/unstake/withdraw
    //      sequence, extract more IDOS than the linear schedule allows?
    // ─────────────────────────────────────────────────────────────────

    /// Honest baseline — at 50% of duration the released total should equal
    /// 50% of principal regardless of how many round-trips happened in between.
    function test_game_round_trips_dont_drift() public {
        vm.startPrank(beneficiary);
        wallet.stakeAt(nodeA, 400_000 ether);
        wallet.stakeAt(nodeB, 300_000 ether);
        wallet.unstakeFrom(nodeA, 100_000 ether);
        vm.warp(block.timestamp + 15 days);
        wallet.withdrawUnstaked();                 // 100k back in wallet
        wallet.stakeAt(nodeB, 50_000 ether);
        vm.stopPrank();

        // Half-way through the schedule
        vm.warp(vStart + vDuration / 2);

        // Get everything back so we can actually release.
        vm.startPrank(beneficiary);
        wallet.unstakeFrom(nodeA, STAKING.stakeByNodeByUser(address(wallet), nodeA));
        wallet.unstakeFrom(nodeB, STAKING.stakeByNodeByUser(address(wallet), nodeB));
        vm.warp(block.timestamp + 15 days);
        wallet.withdrawUnstaked();
        wallet.release(address(IDOS));
        vm.stopPrank();

        // Beneficiary should hold ~half of PRINCIPAL. The "~" comes from the
        // 15-day extra elapsed during the unstake delay — i.e. slightly more
        // than 50% by the time release() fires. We assert it falls inside
        // [50%, 52%] of principal.
        uint256 paid = IDOS.balanceOf(beneficiary);
        assertGe(paid, PRINCIPAL * 50 / 100);
        assertLe(paid, PRINCIPAL * 52 / 100);
    }

    /// Adversarial: try to release more than is vested by manipulating the
    /// reported wallet balance via fast stake/release cycles. Should be
    /// impossible — vestedAmount uses (balance + released + outstandingStake)
    /// which is invariant under stake/unstake operations.
    function test_game_cannot_release_more_than_schedule() public {
        // Many tiny cycles, then release at t = 25% of duration.
        vm.startPrank(beneficiary);
        for (uint i; i < 8; i++) {
            wallet.stakeAt(nodeA, 50_000 ether);
            wallet.unstakeFrom(nodeA, 50_000 ether);
            vm.warp(block.timestamp + 15 days);
            wallet.withdrawUnstaked();
        }
        vm.stopPrank();

        // Now warp to ~25% of total duration counted from vStart
        vm.warp(vStart + vDuration / 4);

        vm.prank(beneficiary);
        wallet.release(address(IDOS));

        // 25% of 1M = 250k. With ~120 days of slop from the loop the actual
        // ratio is higher than 25%; cap at 35% to catch any genuine overpay.
        uint256 paid = IDOS.balanceOf(beneficiary);
        assertLe(paid, PRINCIPAL * 35 / 100);
    }

    /// Stake while wallet is *empty* of free IDOS (everything is already out
    /// at staking). The wallet must not be able to over-approve or pretend to
    /// stake what it doesn't have — safeTransferFrom will simply revert.
    function test_game_overstake_reverts() public {
        vm.startPrank(beneficiary);
        wallet.stakeAt(nodeA, PRINCIPAL);
        vm.expectRevert();                          // ERC20 InsufficientBalance
        wallet.stakeAt(nodeA, 1);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────
    // Q2.  Can VESTING be CIRCUMVENTED?
    //      i.e. can locked IDOS reach the beneficiary EOA before its
    //      scheduled vesting time?
    // ─────────────────────────────────────────────────────────────────

    /// Adversarial: try every public/external entrypoint at t = 0 (nothing
    /// vested yet) and verify the beneficiary EOA stays at zero IDOS.
    function test_circumvent_t0_nothing_leaks() public {
        // Pre-vesting release pays zero (linear schedule from now → 0 vested).
        wallet.release(address(IDOS));
        assertEq(IDOS.balanceOf(beneficiary), 0);

        // Stake + unstake + claim sequence at t=0
        vm.startPrank(beneficiary);
        wallet.stakeAt(nodeA, 500_000 ether);
        wallet.unstakeFrom(nodeA, 500_000 ether);
        vm.warp(block.timestamp + 15 days);
        wallet.withdrawUnstaked();
        wallet.claimVested();                       // releases vested only
        vm.stopPrank();

        // 15 days / 1096 days = 1.37% of principal max
        uint256 paid = IDOS.balanceOf(beneficiary);
        assertLe(paid, PRINCIPAL * 2 / 100);
    }

    /// Adversarial: only the beneficiary can call the stake/unstake/withdraw
    /// surface. Anyone calling them should revert with OnlyBeneficiary.
    function test_circumvent_only_beneficiary_can_stake_etc() public {
        vm.startPrank(attacker);
        vm.expectRevert(IDOSStakingVesting.OnlyBeneficiary.selector);
        wallet.stakeAt(nodeA, 1);

        vm.expectRevert(IDOSStakingVesting.OnlyBeneficiary.selector);
        wallet.unstakeFrom(nodeA, 1);

        vm.expectRevert(IDOSStakingVesting.OnlyBeneficiary.selector);
        wallet.withdrawUnstaked();

        vm.expectRevert(IDOSStakingVesting.OnlyBeneficiary.selector);
        wallet.withdrawReward();
        vm.stopPrank();
    }

    /// Adversarial: anyone can call release() (OZ-by-design) but tokens
    /// always go to owner(). Attacker can't redirect them.
    function test_circumvent_third_party_release_pays_beneficiary() public {
        vm.warp(vStart + vDuration / 4);
        vm.prank(attacker);
        wallet.release(address(IDOS));
        assertGt(IDOS.balanceOf(beneficiary), 0);
        assertEq(IDOS.balanceOf(attacker), 0);
    }

    /// Adversarial: after vestingWallet.approve(...) (which doesn't exist),
    /// the wallet has no IERC20.approve hook. Confirm there is no allowance
    /// to a random address that an attacker could exploit via transferFrom.
    function test_circumvent_no_external_allowance() public {
        assertEq(IDOS.allowance(address(wallet), attacker),       0);
        assertEq(IDOS.allowance(address(wallet), address(this)),  0);

        // Even after a stakeAt that uses forceApprove internally, the
        // allowance to staking is fully consumed and ends at 0 (standard ERC20).
        vm.prank(beneficiary);
        wallet.stakeAt(nodeA, 100_000 ether);
        assertEq(IDOS.allowance(address(wallet), address(STAKING)), 0);
    }

    /// Adversarial: transferOwnership doesn't unlock the schedule. The new
    /// owner inherits release() rights but is still bound by vestedAmount().
    function test_circumvent_transfer_ownership_doesnt_unlock() public {
        vm.prank(beneficiary);
        wallet.transferOwnership(attacker);

        // Attacker (now owner) tries to release pre-schedule → pays 0
        // (vestedAmount before any time elapses is 0).
        vm.prank(attacker);
        wallet.release(address(IDOS));
        assertEq(IDOS.balanceOf(attacker), 0);

        // Even calling stakeAt etc. as new owner can't change schedule.
        vm.prank(attacker);
        wallet.stakeAt(nodeA, 1_000 ether);

        vm.warp(vStart + vDuration / 10);           // 10% elapsed
        vm.prank(attacker);
        wallet.release(address(IDOS));
        // Capped at ~10% + small slop. Definitely not full principal.
        assertLt(IDOS.balanceOf(attacker), PRINCIPAL * 15 / 100);
    }

    /// Reentrancy: owner is a contract whose fallback tries to call back into
    /// the wallet during a release(). Reentrant calls must not result in over-
    /// payment.
    function test_circumvent_reentrant_owner_cannot_drain() public {
        ReentrantBeneficiary evil = new ReentrantBeneficiary();
        evil.setWallet(wallet);

        vm.prank(beneficiary);
        wallet.transferOwnership(address(evil));

        vm.warp(vStart + vDuration / 4);            // 25% vested
        wallet.release(address(IDOS));

        // Even with reentrant fallback, evil cannot receive more than the
        // 25% that was vested at this timestamp.
        assertLe(IDOS.balanceOf(address(evil)), PRINCIPAL * 26 / 100);
    }

    // ─────────────────────────────────────────────────────────────────
    // Q3.  Can tokens get STUCK in the staking contract?
    // ─────────────────────────────────────────────────────────────────

    /// Withdraw-before-delay reverts; tokens are not lost, the queue is
    /// still there and waits for time to pass.
    function test_stuck_premature_withdraw_does_not_lose_tokens() public {
        vm.startPrank(beneficiary);
        wallet.stakeAt(nodeA, 200_000 ether);
        wallet.unstakeFrom(nodeA, 200_000 ether);

        // Only 1 day in — UNSTAKE_DELAY = 14 days
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert();
        wallet.withdrawUnstaked();

        // 14 days later it succeeds
        vm.warp(block.timestamp + 14 days);
        uint256 r = wallet.withdrawUnstaked();
        assertEq(r, 200_000 ether);
        assertEq(wallet.outstandingStake(), 0);
        vm.stopPrank();
    }

    /// After full vesting period and a full unstake round-trip, every IDOS
    /// is back in beneficiary's EOA — nothing is permanently stuck.
    function test_stuck_full_lifecycle_returns_everything() public {
        vm.startPrank(beneficiary);
        wallet.stakeAt(nodeA, PRINCIPAL);

        // Fast-forward past end of schedule.
        vm.warp(vStart + vDuration + 1 days);

        wallet.unstakeFrom(nodeA, PRINCIPAL);
        vm.warp(block.timestamp + 15 days);
        wallet.claimVested();
        vm.stopPrank();

        assertEq(IDOS.balanceOf(beneficiary), PRINCIPAL);
        assertEq(IDOS.balanceOf(address(wallet)), 0);
        assertEq(wallet.outstandingStake(), 0);
    }

    /// Slashing scenario: tokens at a slashed node are lost to the staking
    /// owner. But (a) the rest of the wallet must remain releasable and
    /// (b) release() must not brick due to schedule underflow even if
    /// slashing happens after partial release.
    function test_stuck_slashing_lost_but_rest_still_releasable() public {
        vm.startPrank(beneficiary);
        wallet.stakeAt(nodeA, 600_000 ether);       // will be slashed
        wallet.stakeAt(nodeB, 400_000 ether);       // safe
        vm.stopPrank();

        // Mid-vest, partial release first (force into the "released > new
        // vestedAmount after slash" zone).
        vm.warp(vStart + vDuration / 2);
        vm.startPrank(beneficiary);
        wallet.unstakeFrom(nodeB, 200_000 ether);
        vm.warp(block.timestamp + 15 days);
        wallet.claimVested();
        vm.stopPrank();
        uint256 paidBefore = IDOS.balanceOf(beneficiary);
        assertGt(paidBefore, 0);

        // Owner slashes nodeA → 600k disappears from beneficiary's allocation.
        vm.prank(STAKING_OWNER);
        STAKING.slash(nodeA);

        // release() must NOT revert with underflow even though
        // vestedAmount may have dropped below released.
        vm.warp(block.timestamp + 30 days);
        vm.prank(beneficiary);
        wallet.release(address(IDOS));              // pays 0 or small extra

        uint256 paidAfter = IDOS.balanceOf(beneficiary);
        assertGe(paidAfter, paidBefore);            // monotonic

        // And — critically — the rest of the (non-slashed) stake at nodeB is
        // still recoverable.
        vm.warp(vStart + vDuration + 1 days);
        vm.startPrank(beneficiary);
        wallet.unstakeFrom(nodeB, STAKING.stakeByNodeByUser(address(wallet), nodeB));
        vm.warp(block.timestamp + 15 days);
        wallet.claimVested();
        vm.stopPrank();

        // Final beneficiary holdings = whatever vested out of (principal -
        // slashed 600k). i.e. somewhere in [200k, 400k].
        uint256 final_ = IDOS.balanceOf(beneficiary);
        assertGe(final_, 200_000 ether);
        assertLe(final_, 400_000 ether);
    }

    /// Pausing the staking contract temporarily blocks stake/unstake but
    /// doesn't lose tokens — they stay in the staking contract and are
    /// recoverable on unpause.
    function test_stuck_pause_then_unpause_recovers() public {
        vm.prank(beneficiary);
        wallet.stakeAt(nodeA, 500_000 ether);

        vm.prank(STAKING_OWNER);
        STAKING.pause();

        vm.prank(beneficiary);
        vm.expectRevert();                          // EnforcedPause
        wallet.unstakeFrom(nodeA, 1);

        vm.prank(STAKING_OWNER);
        STAKING.unpause();

        vm.startPrank(beneficiary);
        wallet.unstakeFrom(nodeA, 500_000 ether);
        vm.warp(block.timestamp + 15 days);
        wallet.withdrawUnstaked();
        vm.stopPrank();

        assertEq(IDOS.balanceOf(address(wallet)), PRINCIPAL);
    }

    // ─────────────────────────────────────────────────────────────────
    // Misc invariants
    // ─────────────────────────────────────────────────────────────────

    function test_constructor_rejects_zero_addresses() public {
        vm.expectRevert(IDOSStakingVesting.ZeroAddressToken.selector);
        new IDOSStakingVesting(beneficiary, vStart, vDuration, 0, IERC20(address(0)), STAKING);

        vm.expectRevert(IDOSStakingVesting.ZeroAddressStaking.selector);
        new IDOSStakingVesting(beneficiary, vStart, vDuration, 0, IDOS, IIDOSNodeStaking(address(0)));
    }

    /// Foreign ERC20s sent to the wallet vest on the same schedule
    /// (standard OZ VestingWallet behaviour, but we re-check that our
    /// override of vestedAmount() doesn't break it).
    function test_foreign_token_vests_normally() public {
        DummyToken dmy = new DummyToken();
        dmy.transfer(address(wallet), 100_000 ether);

        vm.warp(vStart + vDuration / 2);
        wallet.release(address(dmy));
        // ~50% of 100k expected, with some slop for any test-time skew.
        assertApproxEqRel(dmy.balanceOf(beneficiary), 50_000 ether, 0.01e18);
    }
}
