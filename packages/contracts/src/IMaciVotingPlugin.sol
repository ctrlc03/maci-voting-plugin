// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMaciVotingPlugin {
    struct VotingSettings {
        uint32 minParticipation;
        uint64 minDuration;
        uint256 minProposerVotingPower;
    }
}
