// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VestingWallet}        from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff}   from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";
import {IERC20}               from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}            from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math}                 from "@openzeppelin/contracts/utils/math/Math.sol";

interface IIDOSNodeStaking {
    function stake(address user, address node, uint256 amount) external;
    function unstake(address node, uint256 amount)             external;
    function withdrawUnstaked()                                 external returns (uint256);
    function withdrawReward()                                   external returns (uint256);
    function getUserStake(address user)                         external view returns (uint256 active, uint256 slashed);
}

/// @notice OpenZeppelin VestingWallet + VestingWalletCliff, plus the ability for
///         the beneficiary to delegate the *locked* IDOS into the canonical
///         IDOSNodeStaking contract without breaking the vesting schedule.
///         Requires NO changes to the staking contract.
contract IDOSStakingVesting is VestingWallet, VestingWalletCliff {
    using SafeERC20 for IERC20;

    IERC20           public immutable IDOS;
    IIDOSNodeStaking public immutable STAKING;

    /// Tokens currently held by the staking contract on this wallet's behalf
    /// (active stake + pending unstake). Decremented only when tokens actually
    /// return via withdrawUnstaked(); never decremented for slashing — slashed
    /// amounts are subtracted live inside vestedAmount() instead.
    uint256 public outstandingStake;

    error OnlyBeneficiary();
    error ZeroAddressToken();
    error ZeroAddressStaking();

    modifier onlyBeneficiary() {
        if (msg.sender != owner()) revert OnlyBeneficiary();
        _;
    }

    constructor(
        address beneficiary,
        uint64  startTimestamp,
        uint64  durationSeconds,
        uint64  cliffSeconds,
        IERC20  idos,
        IIDOSNodeStaking staking
    )
        payable
        VestingWallet(beneficiary, startTimestamp, durationSeconds)
        VestingWalletCliff(cliffSeconds)
    {
        if (address(idos)    == address(0)) revert ZeroAddressToken();
        if (address(staking) == address(0)) revert ZeroAddressStaking();
        IDOS    = idos;
        STAKING = staking;
    }

    // ─── vesting math ─────────────────────────────────────────────────

    /// Adds the live staked balance (net of slashing) to the allocation
    /// total. Otherwise release() would underpay while anything is staked.
    ///
    /// Slashing safety: if slashing reduces the allocation so far that the
    /// linear schedule would return less than what has already been released
    /// (e.g. user released early, then a node they staked into got slashed),
    /// the result is clamped to `released(token)`. That preserves OZ's
    /// invariant "vestedAmount is monotonically non-decreasing over time *and*
    /// is always >= released(token)" — without it, `releasable()` would
    /// underflow and brick all future calls.
    function vestedAmount(address token, uint64 ts)
        public view virtual override returns (uint256)
    {
        uint256 alreadyReleased = released(token);
        uint256 total = IERC20(token).balanceOf(address(this)) + alreadyReleased;
        if (token == address(IDOS)) {
            (, uint256 slashed) = STAKING.getUserStake(address(this));
            uint256 alive = outstandingStake > slashed ? outstandingStake - slashed : 0;
            total += alive;
        }
        return Math.max(_vestingSchedule(total, ts), alreadyReleased);
    }

    /// Cliff override — preserved exactly as in the original IDOSVesting.
    function _vestingSchedule(uint256 totalAllocation, uint64 ts)
        internal view override(VestingWallet, VestingWalletCliff)
        returns (uint256)
    {
        return ts < cliff() ? 0 : super._vestingSchedule(totalAllocation, ts);
    }

    // ─── staking actions ──────────────────────────────────────────────

    function stakeAt(address node, uint256 amount) external onlyBeneficiary {
        outstandingStake += amount;
        IDOS.forceApprove(address(STAKING), amount);
        STAKING.stake(address(this), node, amount);
    }

    function unstakeFrom(address node, uint256 amount) external onlyBeneficiary {
        STAKING.unstake(node, amount);
    }

    function withdrawUnstaked() external onlyBeneficiary returns (uint256 received) {
        uint256 before = IDOS.balanceOf(address(this));
        STAKING.withdrawUnstaked();
        received = IDOS.balanceOf(address(this)) - before;
        outstandingStake -= received;
    }

    /// Rewards land here and vest with the principal. For a "rewards are
    /// immediately free" UX, replace the body with: withdraw, then
    /// IDOS.safeTransfer(owner(), received).
    function withdrawReward() external onlyBeneficiary returns (uint256 amount) {
        return STAKING.withdrawReward();
    }

    /// Convenience: tries to pull any unstake-ripe IDOS back into the wallet,
    /// then sends the currently-vested portion to the beneficiary. Permissionless
    /// on purpose — every code path is favourable to the beneficiary, and the
    /// withdraw step silently no-ops if nothing is ready (avoiding a revert on
    /// the staking contract's NoWithdrawableStake error).
    function claimVested() external returns (uint256 releasedAmount, uint256 unstakedReturned) {
        try STAKING.withdrawUnstaked() returns (uint256 r) {
            unstakedReturned = r;
            outstandingStake -= r;
        } catch {
            // Nothing in the unstake queue is ripe yet — that's fine, fall
            // through to release() so any time-vested portion still pays out.
        }
        uint256 before = IDOS.balanceOf(owner());
        release(address(IDOS));
        releasedAmount = IDOS.balanceOf(owner()) - before;
    }
}
