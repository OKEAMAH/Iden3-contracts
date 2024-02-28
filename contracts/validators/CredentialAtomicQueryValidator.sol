// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.16;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {GenesisUtils} from "../lib/GenesisUtils.sol";
import {ICircuitValidator} from "../interfaces/ICircuitValidator.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {IState} from "../interfaces/IState.sol";
import {PoseidonFacade} from "../lib/Poseidon.sol";

abstract contract CredentialAtomicQueryValidator is OwnableUpgradeable, ICircuitValidator, ERC165 {
    struct CredentialAtomicQuery {
        uint256 schema;
        uint256 claimPathKey;
        uint256 operator;
        uint256 slotIndex;
        uint256[] value;
        uint256 queryHash;
        uint256[] allowedIssuers;
        string[] circuitIds;
        bool skipClaimRevocationCheck;
        // 0 for inclusion in merklized credentials, 1 for non-inclusion and for non-merklized credentials
        uint256 claimPathNotExists;
    }

    struct CommonPubSignals {
        uint256 merklized;
        uint256 userID;
        uint256 issuerState;
        uint256 circuitQueryHash;
        uint256 requestID;
        uint256 challenge;
        uint256 gistRoot;
        uint256 issuerID;
        uint256 isRevocationChecked;
        uint256 issuerClaimNonRevState;
        uint256 timestamp;
    }

    /// @dev Main storage structure for the contract
    struct MainStorage {
        mapping(string => IVerifier) _circuitIdToVerifier;
        string[] _supportedCircuitIds;
        IState state;
        uint256 revocationStateExpirationTimeout;
        uint256 proofExpirationTimeout;
        uint256 gistRootExpirationTimeout;
        mapping(string => uint256) _inputNameToIndex;
    }

    // keccak256(abi.encode(uint256(keccak256("iden3.storage.CredentialAtomicQueryValidator")) - 1))
    //  & ~bytes32(uint256(0xff));
    bytes32 private constant CRED_ATOMIC_QUERY_VERIFIER_STORAGE_LOCATION =
        0x28c92975a30f1f2f7970a65953987652034d896ba2d3b7a4961ada9e18287500;

    /// @dev Get the main storage using assembly to ensure specific storage location
    function _getMainStorage() internal pure returns (MainStorage storage $) {
        assembly {
            $.slot := CRED_ATOMIC_QUERY_VERIFIER_STORAGE_LOCATION
        }
    }

    function initialize(
        address _verifierContractAddr,
        address _stateContractAddr
    ) public virtual onlyInitializing {
        MainStorage storage s = _getMainStorage();

        s.revocationStateExpirationTimeout = 1 hours;
        s.proofExpirationTimeout = 1 hours;
        s.gistRootExpirationTimeout = 1 hours;
        s.state = IState(_stateContractAddr);
        __Ownable_init();
    }

    function version() public pure virtual returns (string memory);

    function parseCommonPubSignals(
        uint256[] calldata inputs
    ) public pure virtual returns (CommonPubSignals memory);

    function setRevocationStateExpirationTimeout(
        uint256 expirationTimeout
    ) public virtual onlyOwner {
        _getMainStorage().revocationStateExpirationTimeout = expirationTimeout;
    }

    function getRevocationStateExpirationTimeout() public view virtual returns (uint256) {
        return _getMainStorage().revocationStateExpirationTimeout;
    }

    function setProofExpirationTimeout(uint256 expirationTimeout) public virtual onlyOwner {
        _getMainStorage().proofExpirationTimeout = expirationTimeout;
    }

    function getProofExpirationTimeout() public view virtual returns (uint256) {
        return _getMainStorage().proofExpirationTimeout;
    }

    function setGISTRootExpirationTimeout(uint256 expirationTimeout) public virtual onlyOwner {
        _getMainStorage().gistRootExpirationTimeout = expirationTimeout;
    }

    function getGISTRootExpirationTimeout() public view virtual returns (uint256) {
        return _getMainStorage().gistRootExpirationTimeout;
    }

    function setStateAddress(address stateContractAddr) public virtual onlyOwner {
        _getMainStorage().state = IState(stateContractAddr);
    }

    function getStateAddress() public view virtual returns (address) {
        return address(_getMainStorage().state);
    }

    function verify(
        uint256[] calldata inputs,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        bytes calldata data,
        address sender
    ) external view virtual returns (ICircuitValidator.KeyToInputIndex[] memory) {
        return _verify(inputs, a, b, c, data, sender);
    }

    function getSupportedCircuitIds() external view virtual returns (string[] memory ids) {
        return _getMainStorage()._supportedCircuitIds;
    }

    function inputIndexOf(string memory name) public view virtual returns (uint256) {
        uint256 index = _getMainStorage()._inputNameToIndex[name];
        require(index != 0, "Input name not found");
        return --index; // we save 1-based index, but return 0-based
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(ICircuitValidator).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _verify(
        uint256[] calldata inputs,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        bytes calldata data,
        address sender
    ) internal view virtual returns (ICircuitValidator.KeyToInputIndex[] memory) {
        CredentialAtomicQuery memory credAtomicQuery = abi.decode(data, (CredentialAtomicQuery));
        IVerifier verifier = _getMainStorage()._circuitIdToVerifier[credAtomicQuery.circuitIds[0]];

        require(
            credAtomicQuery.circuitIds.length == 1 && verifier != IVerifier(address(0)),
            "Invalid circuit ID"
        );

        // verify that zkp is valid
        require(verifier.verify(a, b, c, inputs), "Proof is not valid");

        CommonPubSignals memory signals = parseCommonPubSignals(inputs);

        // check circuitQueryHash
        require(
            signals.circuitQueryHash == credAtomicQuery.queryHash,
            "Query hash does not match the requested one"
        );

        // TODO: add support for query to specific userID and then verifying it

        _checkMerklized(signals.merklized, credAtomicQuery.claimPathKey);
        _checkGistRoot(signals.gistRoot);
        _checkAllowedIssuers(signals.issuerID, credAtomicQuery.allowedIssuers);
        _checkClaimIssuanceState(signals.issuerID, signals.issuerState);
        _checkClaimNonRevState(signals.issuerID, signals.issuerClaimNonRevState);
        _checkProofExpiration(signals.timestamp);
        _checkIsRevocationChecked(
            signals.isRevocationChecked,
            credAtomicQuery.skipClaimRevocationCheck
        );

        ICircuitValidator.KeyToInputIndex[] memory pairs = _getSpecialInputPairs(
            credAtomicQuery.operator == 16
        );
        return pairs;
    }

    function _checkGistRoot(uint256 gistRoot) internal view {
        MainStorage storage s = _getMainStorage();
        IState.GistRootInfo memory rootInfo = s.state.getGISTRootInfo(gistRoot);
        require(rootInfo.root == gistRoot, "Gist root state isn't in state contract");
        if (
            rootInfo.replacedAtTimestamp != 0 &&
            block.timestamp - rootInfo.replacedAtTimestamp > s.gistRootExpirationTimeout
        ) {
            revert("Gist root is expired");
        }
    }

    function _checkClaimIssuanceState(uint256 _id, uint256 _state) internal view {
        bool isStateGenesis = GenesisUtils.isGenesisState(_id, _state);

        if (!isStateGenesis) {
            IState.StateInfo memory stateInfo = _getMainStorage().state.getStateInfoByIdAndState(
                _id,
                _state
            );
            require(_id == stateInfo.id, "State doesn't exist in state contract");
        }
    }

    function _checkClaimNonRevState(uint256 _id, uint256 _claimNonRevState) internal view {
        MainStorage storage s = _getMainStorage();

        // check if identity transited any state in contract
        bool idExists = s.state.idExists(_id);

        // if identity didn't transit any state it must be genesis
        if (!idExists) {
            require(
                GenesisUtils.isGenesisState(_id, _claimNonRevState),
                "Issuer revocation state doesn't exist in state contract and is not genesis"
            );
        } else {
            IState.StateInfo memory claimNonRevStateInfo = s.state.getStateInfoById(_id);
            // The non-empty state is returned, and it's not equal to the state that the user has provided.
            if (claimNonRevStateInfo.state != _claimNonRevState) {
                // Get the time of the latest state and compare it to the transition time of state provided by the user.
                IState.StateInfo memory claimNonRevLatestStateInfo = s
                    .state
                    .getStateInfoByIdAndState(_id, _claimNonRevState);

                if (claimNonRevLatestStateInfo.id == 0 || claimNonRevLatestStateInfo.id != _id) {
                    revert("State in transition info contains invalid id");
                }

                if (claimNonRevLatestStateInfo.replacedAtTimestamp == 0) {
                    revert("Non-Latest state doesn't contain replacement information");
                }

                if (
                    block.timestamp - claimNonRevLatestStateInfo.replacedAtTimestamp >
                    s.revocationStateExpirationTimeout
                ) {
                    revert("Non-Revocation state of Issuer expired");
                }
            }
        }
    }

    function _checkProofExpiration(uint256 _proofGenerationTimestamp) internal view {
        if (_proofGenerationTimestamp > block.timestamp) {
            revert("Proof generated in the future is not valid");
        }
        if (
            block.timestamp - _proofGenerationTimestamp > _getMainStorage().proofExpirationTimeout
        ) {
            revert("Generated proof is outdated");
        }
    }

    function _checkAllowedIssuers(uint256 issuerId, uint256[] memory allowedIssuers) internal pure {
        // empty array is 'allow all' equivalent - ['*']
        if (allowedIssuers.length == 0) {
            return;
        }

        for (uint i = 0; i < allowedIssuers.length; i++) {
            if (issuerId == allowedIssuers[i]) {
                return;
            }
        }

        revert("Issuer is not on the Allowed Issuers list");
    }

    function _checkMerklized(uint256 merklized, uint256 queryClaimPathKey) internal pure {
        uint256 shouldBeMerklized = queryClaimPathKey != 0 ? 1 : 0;
        require(merklized == shouldBeMerklized, "Merklized value is not correct");
    }

    function _checkIsRevocationChecked(
        uint256 isRevocationChecked,
        bool skipClaimRevocationCheck
    ) internal pure {
        uint256 expectedIsRevocationChecked = 1;
        if (skipClaimRevocationCheck) {
            expectedIsRevocationChecked = 0;
        }
        require(
            isRevocationChecked == expectedIsRevocationChecked,
            "Revocation check should match the query"
        );
    }

    function _setInputToIndex(string memory inputName, uint256 index) internal {
        _getMainStorage()._inputNameToIndex[inputName] = ++index; // increment index to avoid 0
    }

    function _getSpecialInputPairs(
        bool hasSelectiveDisclosure
    ) internal pure virtual returns (ICircuitValidator.KeyToInputIndex[] memory);
}
