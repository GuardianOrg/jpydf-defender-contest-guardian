// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IInitiative
 * @notice ABI-compatible hook surface with Liquity V2-gov initiatives.
 */
interface IInitiative {
    struct Allocation {
        uint256 voteLQTY;
        uint256 voteOffset;
        uint256 vetoLQTY;
        uint256 vetoOffset;
        uint256 atEpoch;
    }

    struct UserState {
        uint256 unallocatedLQTY;
        uint256 unallocatedOffset;
        uint256 allocatedLQTY;
        uint256 allocatedOffset;
    }

    struct InitiativeState {
        uint256 voteLQTY;
        uint256 voteOffset;
        uint256 vetoLQTY;
        uint256 vetoOffset;
        uint256 lastEpochClaim;
    }

    function onRegisterInitiative(uint256 _atEpoch) external;

    function onUnregisterInitiative(uint256 _atEpoch) external;

    function onAfterAllocateLQTY(
        uint256 _currentEpoch,
        address _user,
        UserState calldata _userState,
        Allocation calldata _allocation,
        InitiativeState calldata _initiativeState
    ) external;

    function onClaimForInitiative(uint256 _claimEpoch, uint256 _jpydf) external;
}
