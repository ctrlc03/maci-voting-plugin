// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {PluginUUPSUpgradeable} from "@aragon/osx-commons-contracts/src/plugin/PluginUUPSUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {ProposalUpgradeable} from "@aragon/osx-commons-contracts/src/plugin/extensions/proposal/ProposalUpgradeable.sol";
import {RATIO_BASE, _applyRatioCeiled} from "./Utils.sol";
import {IMaciVotingPlugin} from "./IMaciVotingPlugin.sol";

import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IMACI} from "maci-contracts/contracts/interfaces/IMACI.sol";
import {Params} from "maci-contracts/contracts/utilities/Params.sol";
import {DomainObjs} from "maci-contracts/contracts/utilities/DomainObjs.sol";

/// @title MyPlugin
/// @dev Release 1, Build 1
/// @notice Each voter gets voting power based on their token balance snapshot
/// Voters can vote for option 0 or 1 (yes or no)
/// Abstain - signed up but not voted (needs changes in the MACI protocol to keep track of that)
/// What about minimum participation?
contract MaciVoting is PluginUUPSUpgradeable, ProposalUpgradeable, IMaciVotingPlugin {
    using SafeCastUpgradeable for uint256;

    /// @notice The [ERC-165](https://eips.ethereum.org/EIPS/eip-165) interface ID of the contract.
    bytes4 internal constant MACI_VOTING_INTERFACE_ID =
        this.initialize.selector ^ this.getVotingToken.selector;

    /// @notice An [OpenZeppelin `Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes) compatible contract referencing the token being used for voting.
    IVotesUpgradeable private votingToken;

    /// @notice The ID of the permission required to call the `storeNumber` function.
    bytes32 public constant CREATE_PROPOSAL_PERMISSION_ID = keccak256("CREATE_PROPOSAL_PERMISSION");

    /// @notice The address of the maci contract.
    IMACI public maci;

    /// @notice The coordinator public key.
    /// @dev We do not allow it to be passed per poll as we want the DAO to control this for now
    DomainObjs.PubKey public coordinatorPubKey;

    /// @notice The voting settings.
    VotingSettings public votingSettings;

    /// @notice The proposals.
    Proposal[] public proposals;

    error ProposalCreationForbidden(address _address);
    error NoVotingPower();
    error DateOutOfBounds(uint64 limit, uint64 actual);

    /// @notice A container for the proposal parameters at the time of proposal creation.
    /// @param startDate The start date of the proposal vote.
    /// @param endDate The end date of the proposal vote.
    /// @param snapshotBlock The number of the block prior to the proposal creation.
    /// @param minVotingPower The minimum voting power needed.
    struct ProposalParameters {
        uint64 startDate;
        uint64 endDate;
        uint64 snapshotBlock;
        uint256 minVotingPower;
    }

    /// @notice A container for proposal-related information.
    /// @param executed Whether the proposal is executed or not.
    /// @param parameters The proposal parameters at the time of the proposal creation.
    /// @param actions The actions to be executed when the proposal passes.
    /// @param allowFailureMap A bitmap allowing the proposal to succeed, even if individual actions might revert. If the bit at index `i` is 1, the proposal succeeds even if the `i`th action reverts. A failure map value of 0 requires every action to not revert.
    struct Proposal {
        bool executed;
        ProposalParameters parameters;
        IDAO.Action[] actions;
        uint256 allowFailureMap;
    }

    /// @notice Disables the initializers on the implementation contract to prevent it from being left uninitialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the plugin when build 1 is installed.
    /// @param _dao The address of the DAO.
    /// @param _maci The address of the maci contract.
    /// @param _coordinatorPubKey The coordinator public key.
    /// @param _votingSettings The voting settings.
    function initialize(
        IDAO _dao,
        address _maci,
        DomainObjs.PubKey calldata _coordinatorPubKey,
        VotingSettings calldata _votingSettings
    ) external initializer {
        __PluginUUPSUpgradeable_init(_dao);

        maci = IMACI(_maci);
        coordinatorPubKey = _coordinatorPubKey;
        votingSettings = _votingSettings;
    }

    /// @notice Returns the minimum voting power required to create a proposal stored in the voting settings.
    /// @return The minimum voting power required to create a proposal.
    function minProposerVotingPower() public view virtual returns (uint256) {
        return votingSettings.minProposerVotingPower;
    }

    function totalVotingPower(uint256 _blockNumber) public view returns (uint256) {
        return votingToken.getPastTotalSupply(_blockNumber);
    }

    function getVotingToken() public view returns (IVotesUpgradeable) {
        return votingToken;
    }

    /// @notice Creates a proposal.
    /// @param _metadata The metadata of the proposal.
    /// @param _actions The actions of the proposal.
    /// @param _allowFailureMap The allow failure map of the proposal.
    /// @param _startDate The start date of the proposal.
    /// @param _endDate The end date of the proposal.
    function createProposal(
        bytes calldata _metadata,
        IDAO.Action[] calldata _actions,
        uint256 _allowFailureMap,
        uint64 _startDate,
        uint64 _endDate
    ) external returns (uint256 proposalId) {
        // Check that either `_msgSender` owns enough tokens or has enough voting power from being a delegatee.
        {
            uint256 minProposerVotingPower_ = minProposerVotingPower();

            if (minProposerVotingPower_ != 0) {
                // Because of the checks in `TokenVotingSetup`, we can assume that `votingToken` is an [ERC-20](https://eips.ethereum.org/EIPS/eip-20) token.
                if (
                    votingToken.getVotes(_msgSender()) < minProposerVotingPower_ &&
                    IERC20Upgradeable(address(votingToken)).balanceOf(_msgSender()) <
                    minProposerVotingPower_
                ) {
                    revert ProposalCreationForbidden(_msgSender());
                }
            }
        }

        uint256 snapshotBlock;
        unchecked {
            snapshotBlock = block.number - 1; // The snapshot block must be mined already to protect the transaction against backrunning transactions causing census changes.
        }

        uint256 totalVotingPower_ = totalVotingPower(snapshotBlock);

        if (totalVotingPower_ == 0) {
            revert NoVotingPower();
        }

        (_startDate, _endDate) = _validateProposalDates(_startDate, _endDate);

        proposalId = _createProposal({
            _creator: _msgSender(),
            _metadata: _metadata,
            _startDate: _startDate,
            _endDate: _endDate,
            _actions: _actions,
            _allowFailureMap: _allowFailureMap
        });

        // Store proposal related information
        Proposal storage proposal_ = proposals[proposalId];

        proposal_.parameters.startDate = _startDate;
        proposal_.parameters.endDate = _endDate;
        proposal_.parameters.snapshotBlock = snapshotBlock.toUint64();
        proposal_.parameters.minVotingPower = _applyRatioCeiled(
            totalVotingPower_,
            minParticipation()
        );

        // Reduce costs
        if (_allowFailureMap != 0) {
            proposal_.allowFailureMap = _allowFailureMap;
        }

        for (uint256 i; i < _actions.length; ) {
            proposal_.actions.push(_actions[i]);
            unchecked {
                ++i;
            }
        }

        Params.TreeDepths memory treeDepths = Params.TreeDepths({
            intStateTreeDepth: 2,
            voteOptionTreeDepth: 1
        });

        address[] memory relayers = new address[](1);
        relayers[0] = address(0);

        // Arguments to deploy a poll
        IMACI.DeployPollArgs memory deployPollArgs = IMACI.DeployPollArgs({
            duration: _endDate - _startDate,
            treeDepths: treeDepths,
            messageBatchSize: 20,
            coordinatorPubKey: coordinatorPubKey,
            verifier: address(0),
            vkRegistry: address(0),
            mode: DomainObjs.Mode.NON_QV,
            gatekeeper: address(this),
            initialVoiceCreditProxy: address(this),
            relayers: relayers
        });

        IMACI(maci).deployPoll(deployPollArgs);
    }

    /// @notice Votes for a proposal.
    /// @param _proposalId The ID of the proposal.
    function vote(uint256 _proposalId) public {
        Proposal memory proposal_ = proposals[_proposalId];
    }

    /**
     * Gatekeeper function to register users
     */
    function register(address _address, bytes memory _data) public {}

    /**
     * Function to get the voice credits of a user based on their token balances
     */
    function getVoiceCredits(address _address, bytes memory _data) public view returns (uint256) {
        uint256 snapshotBlock = abi.decode(_data, (uint256));
        uint256 votingPower = votingToken.getPastVotes(_address, snapshotBlock);
        return votingPower;
    }

    function minParticipation() public view virtual returns (uint32) {
        return votingSettings.minParticipation;
    }

    /// @notice Validates and returns the proposal vote dates.
    /// @param _start The start date of the proposal vote. If 0, the current timestamp is used and the vote starts immediately.
    /// @param _end The end date of the proposal vote. If 0, `_start + minDuration` is used.
    /// @return startDate The validated start date of the proposal vote.
    /// @return endDate The validated end date of the proposal vote.
    function _validateProposalDates(
        uint64 _start,
        uint64 _end
    ) internal view virtual returns (uint64 startDate, uint64 endDate) {
        uint64 currentTimestamp = block.timestamp.toUint64();

        if (_start == 0) {
            startDate = currentTimestamp;
        } else {
            startDate = _start;

            if (startDate < currentTimestamp) {
                revert DateOutOfBounds({limit: currentTimestamp, actual: startDate});
            }
        }

        uint64 earliestEndDate = startDate + votingSettings.minDuration; // Since `minDuration` is limited to 1 year, `startDate + minDuration` can only overflow if the `startDate` is after `type(uint64).max - minDuration`. In this case, the proposal creation will revert and another date can be picked.

        if (_end == 0) {
            endDate = earliestEndDate;
        } else {
            endDate = _end;

            if (endDate < earliestEndDate) {
                revert DateOutOfBounds({limit: earliestEndDate, actual: endDate});
            }
        }
    }

    /// @notice Checks if this or the parent contract supports an interface by its ID.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(
        bytes4 _interfaceId
    ) public view virtual override(PluginUUPSUpgradeable, ProposalUpgradeable) returns (bool) {
        return _interfaceId == MACI_VOTING_INTERFACE_ID || super.supportsInterface(_interfaceId);
    }
}
