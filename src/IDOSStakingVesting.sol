// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {VestingWallet}        from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff}   from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";
import {IERC20}               from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}            from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
        IDOS    = idos;
        STAKING = staking;
    }

    // ─── vesting math ─────────────────────────────────────────────────

    /// Adds the live staked balance (net of slashing) to the allocation
    /// total. Otherwise release() would underpay while anything is staked.
    function vestedAmount(address token, uint64 ts)
        public view virtual override returns (uint256)
    {
        uint256 total = IERC20(token).balanceOf(address(this)) + released(token);
        if (token == address(IDOS)) {
            (, uint256 slashed) = STAKING.getUserStake(address(this));
            uint256 alive = outstandingStake > slashed ? outstandingStake - slashed : 0;
            total += alive;
        }
        return _vestingSchedule(total, ts);
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
}
