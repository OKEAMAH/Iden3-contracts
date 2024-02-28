// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.16;

import {CredentialAtomicQueryValidator} from "./CredentialAtomicQueryValidator.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {PrimitiveTypeUtils} from "../lib/PrimitiveTypeUtils.sol";
import {GenesisUtils} from "../lib/GenesisUtils.sol";
import {ICircuitValidator} from "../interfaces/ICircuitValidator.sol";

/**
 * @dev CredentialAtomicQueryV3 validator
 */
contract CredentialAtomicQueryV3Validator is CredentialAtomicQueryValidator {
    struct CredentialAtomicQueryV3 {
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
        uint256 groupID;
        uint256 nullifierSessionID;
        uint256 proofType;
        uint256 verifierID;
    }

    struct V3PubSignals {
        uint256 linkID;
        uint256 nullifier;
        uint256 operatorOutput;
        uint256 proofType;
        uint256 verifierID;
        uint256 nullifierSessionID;
        uint256 isBJJAuthEnabled;
    }

    /**
     * @dev Version of contract
     */
    string public constant VERSION = "2.0.0-beta.0";

    string internal constant CIRCUIT_ID = "credentialAtomicQueryV3OnChain-beta.0";

    function initialize(
        address _verifierContractAddr,
        address _stateContractAddr
    ) public override initializer {
        _setInputToIndex("merklized", 0);
        _setInputToIndex("userID", 1);
        _setInputToIndex("circuitQueryHash", 2);
        _setInputToIndex("issuerState", 3);
        _setInputToIndex("linkID", 4);
        _setInputToIndex("nullifier", 5);
        _setInputToIndex("operatorOutput", 6);
        _setInputToIndex("proofType", 7);
        _setInputToIndex("requestID", 8);
        _setInputToIndex("challenge", 9);
        _setInputToIndex("gistRoot", 10);
        _setInputToIndex("issuerID", 11);
        _setInputToIndex("isRevocationChecked", 12);
        _setInputToIndex("issuerClaimNonRevState", 13);
        _setInputToIndex("timestamp", 14);
        _setInputToIndex("verifierID", 15);
        _setInputToIndex("nullifierSessionID", 16);
        _setInputToIndex("authEnabled", 17);

        MainStorage storage s = _getMainStorage();
        s._supportedCircuitIds = [CIRCUIT_ID];
        s._circuitIdToVerifier[CIRCUIT_ID] = IVerifier(_verifierContractAddr);
        super.initialize(_verifierContractAddr, _stateContractAddr);
    }

    function version() public pure override returns (string memory) {
        return VERSION;
    }

    function parseCommonPubSignals(
        uint256[] calldata inputs
    ) public pure override returns (CommonPubSignals memory) {
        CommonPubSignals memory pubSignals = CommonPubSignals({
            merklized: inputs[0],
            userID: inputs[1],
            circuitQueryHash: inputs[2],
            requestID: inputs[8],
            challenge: inputs[9],
            gistRoot: inputs[10],
            issuerID: inputs[11],
            issuerState: inputs[3],
            isRevocationChecked: inputs[12],
            issuerClaimNonRevState: inputs[13],
            timestamp: inputs[14]
        });

        return pubSignals;
    }

    function parseV3SpecificPubSignals(
        uint256[] calldata inputs
    ) internal pure returns (V3PubSignals memory) {
        V3PubSignals memory pubSignals = V3PubSignals({
            linkID: inputs[4],
            nullifier: inputs[5],
            operatorOutput: inputs[6],
            proofType: inputs[7],
            verifierID: inputs[15],
            nullifierSessionID: inputs[16],
            isBJJAuthEnabled: inputs[17]
        });

        return pubSignals;
    }

    function _verify(
        uint256[] calldata inputs,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        bytes calldata data,
        address sender
    ) internal view override returns (ICircuitValidator.KeyToInputIndex[] memory) {
        CredentialAtomicQueryV3 memory credAtomicQuery = abi.decode(
            data,
            (CredentialAtomicQueryV3)
        );

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

        _checkAllowedIssuers(signals.issuerID, credAtomicQuery.allowedIssuers);
        _checkClaimIssuanceState(signals.issuerID, signals.issuerState);
        _checkClaimNonRevState(signals.issuerID, signals.issuerClaimNonRevState);
        _checkProofExpiration(signals.timestamp);
        _checkIsRevocationChecked(
            signals.isRevocationChecked,
            credAtomicQuery.skipClaimRevocationCheck
        );

        V3PubSignals memory v3PubSignals = parseV3SpecificPubSignals(inputs);
        _checkVerifierID(credAtomicQuery.verifierID, v3PubSignals.verifierID);
        _checkNullifierSessionID(
            credAtomicQuery.nullifierSessionID,
            v3PubSignals.nullifierSessionID
        );
        _checkLinkID(credAtomicQuery.groupID, v3PubSignals.linkID);
        _checkProofType(credAtomicQuery.proofType, v3PubSignals.proofType);
        _checkNullify(v3PubSignals.nullifier, credAtomicQuery.nullifierSessionID);

        if (v3PubSignals.isBJJAuthEnabled == 1) {
            _checkGistRoot(signals.gistRoot);
        } else {
            _checkAuth(signals.userID, sender);
        }

        // Checking challenge to prevent replay attacks from other addresses
        _checkChallenge(signals.challenge, sender);

        ICircuitValidator.KeyToInputIndex[] memory pairs = _getSpecialInputPairs(
            credAtomicQuery.operator == 16
        );
        return pairs;
    }

    function _checkVerifierID(uint256 queryVerifierID, uint256 pubSignalVerifierID) internal pure {
        require(
            queryVerifierID == 0 || queryVerifierID == pubSignalVerifierID,
            "Verifier ID should match the query"
        );
    }

    function _checkNullifierSessionID(
        uint256 queryNullifierSessionID,
        uint256 pubSignalNullifierSessionID
    ) internal pure {
        require(
            queryNullifierSessionID == pubSignalNullifierSessionID,
            "Nullifier session ID should match the query"
        );
    }

    function _checkLinkID(uint256 groupID, uint256 linkID) internal pure {
        require(
            (groupID == 0 && linkID == 0) || (groupID != 0 && linkID != 0),
            "Invalid Link ID pub signal"
        );
    }

    function _checkProofType(uint256 queryProofType, uint256 pubSignalProofType) internal pure {
        require(
            queryProofType == 0 || queryProofType == pubSignalProofType,
            "Proof type should match the requested one in query"
        );
    }

    function _checkNullify(uint256 nullifier, uint256 nullifierSessionID) internal pure {
        require(nullifierSessionID == 0 || nullifier != 0, "Invalid nullify pub signal");
    }

    function _checkAuth(uint256 userID, address ethIdentityOwner) internal view {
        require(
            userID ==
                GenesisUtils.calcIdFromEthAddress(
                    _getMainStorage().state.getDefaultIdType(),
                    ethIdentityOwner
                ),
            "UserID does not correspond to the sender"
        );
    }

    function _getSpecialInputPairs(
        bool hasSelectiveDisclosure
    ) internal pure override returns (ICircuitValidator.KeyToInputIndex[] memory) {
        uint256 numPairs = hasSelectiveDisclosure ? 7 : 6;
        ICircuitValidator.KeyToInputIndex[] memory pairs = new ICircuitValidator.KeyToInputIndex[](
            numPairs
        );

        uint i = 0;
        pairs[i++] = ICircuitValidator.KeyToInputIndex({key: "userID", inputIndex: 1});
        pairs[i++] = ICircuitValidator.KeyToInputIndex({key: "linkID", inputIndex: 4});
        pairs[i++] = ICircuitValidator.KeyToInputIndex({key: "nullifier", inputIndex: 5});
        if (hasSelectiveDisclosure) {
            pairs[i++] = ICircuitValidator.KeyToInputIndex({key: "operatorOutput", inputIndex: 6});
        }
        pairs[i++] = ICircuitValidator.KeyToInputIndex({key: "timestamp", inputIndex: 14});
        pairs[i++] = ICircuitValidator.KeyToInputIndex({key: "verifierID", inputIndex: 15});
        pairs[i++] = ICircuitValidator.KeyToInputIndex({key: "nullifierSessionID", inputIndex: 16});

        return pairs;
    }

    function _checkChallenge(uint256 challenge, address sender) internal view {
        require(
            PrimitiveTypeUtils.int256ToAddress(challenge) == sender,
            "Challenge should match the sender"
        );
    }
}
