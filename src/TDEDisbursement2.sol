// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20}              from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}           from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDOSStakingVesting, IIDOSNodeStaking} from "./IDOSStakingVesting.sol";

/// @notice Drop-in replacement for TDEDisbursement that deploys
///         IDOSStakingVesting wallets instead of plain IDOSVesting.
///         Same modality table, same CREATE2 pattern — but a different
///         salt domain so addresses don't collide with the v1 factory.
enum Modality {
    DIRECT,
    VESTED_0_12,
    VESTED_0_120,
    VESTED_1_5,
    VESTED_1_6,
    VESTED_1_60,
    VESTED_6_12,
    VESTED_6_24,
    VESTED_12_24,
    VESTED_12_36
}

contract TDEDisbursement2 {
    using SafeERC20 for IERC20;

    IERC20             public immutable IDOS_TOKEN;
    address            public immutable DISBURSER;
    IIDOSNodeStaking   public immutable STAKING;

    mapping(address beneficiary => mapping(Modality => IDOSStakingVesting)) public vestingContracts;

    event Disbursed(address indexed beneficiary, address transferTarget, uint256 amount, Modality modality);

    error DirectIsNotVested();
    error UnknownModality(Modality modality);
    error ZeroAddressToken();
    error ZeroAddressDisburser();
    error ZeroAddressStaking();
    error ZeroAddressBeneficiary();
    error OnlyCallableByDisburser();

    constructor(IERC20 idosToken, address disburser, IIDOSNodeStaking staking) {
        if (address(idosToken) == address(0)) revert ZeroAddressToken();
        if (disburser          == address(0)) revert ZeroAddressDisburser();
        if (address(staking)   == address(0)) revert ZeroAddressStaking();
        IDOS_TOKEN = idosToken;
        DISBURSER  = disburser;
        STAKING    = staking;
    }

    modifier onlyDisburser() {
        if (msg.sender != DISBURSER) revert OnlyCallableByDisburser();
        _;
    }

    function disburse(address beneficiary, uint256 amount, Modality modality) external onlyDisburser {
        if (beneficiary == address(0)) revert ZeroAddressBeneficiary();
        address transferTarget = beneficiary;
        if (modality != Modality.DIRECT) {
            (IDOSStakingVesting v, ) = ensureVestingContractExists(beneficiary, modality);
            transferTarget = address(v);
        }
        IDOS_TOKEN.safeTransferFrom(DISBURSER, transferTarget, amount);
        emit Disbursed(beneficiary, transferTarget, amount, modality);
    }

    function ensureVestingContractExists(address beneficiary, Modality modality)
        public onlyDisburser
        returns (IDOSStakingVesting vestingContract, bool created)
    {
        vestingContract = vestingContracts[beneficiary][modality];
        if (address(vestingContract) == address(0)) {
            (uint64 start, uint64 duration, uint64 cliff) = VESTING_PARAMS_FOR_MODALITY(modality);
            // Salt namespace includes "v2" so CREATE2 doesn't collide with
            // the v1 factory's deployments for the same (beneficiary, modality).
            bytes32 salt = keccak256(abi.encode("IDOSStakingVesting.v2", beneficiary, modality));
            vestingContract = new IDOSStakingVesting{salt: salt}(
                beneficiary, start, duration, cliff, IDOS_TOKEN, STAKING
            );
            vestingContracts[beneficiary][modality] = vestingContract;
            created = true;
        }
    }

    /// Same schedule table as TDEDisbursement v1 — adjust if you also want to
    /// fix FCL Months 2-6 to be (start, 6 months, 0 cliff) etc.
    function VESTING_PARAMS_FOR_MODALITY(Modality modality)
        public pure
        returns (uint64 startTimestamp, uint64 durationSeconds, uint64 cliffSeconds)
    {
        if (modality == Modality.DIRECT)        revert DirectIsNotVested();
        if (modality == Modality.VESTED_0_12)   return (1770303600, 31536000,  2419200);
        if (modality == Modality.VESTED_0_120)  return (1770303600, 315532800, 2419200);
        if (modality == Modality.VESTED_1_5)    return (1772722800, 13219200,  2678400);
        if (modality == Modality.VESTED_1_6)    return (1772722800, 15897600,  2678400);
        if (modality == Modality.VESTED_1_60)   return (1772722800, 157766400, 2678400);
        if (modality == Modality.VESTED_6_12)   return (1785942000, 31536000,  2678400);
        if (modality == Modality.VESTED_6_24)   return (1785942000, 63158400,  2678400);
        if (modality == Modality.VESTED_12_24)  return (1801839600, 63158400,  2419200);
        if (modality == Modality.VESTED_12_36)  return (1801839600, 94694400,  2419200);
        revert UnknownModality(modality);
    }
}
