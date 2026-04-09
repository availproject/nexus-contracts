// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "./helpers/NexusSettlerTestBase.sol";
import "../src/NexusSettler.sol";
import "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title NexusSettlerTest
 * @notice Tests for zero-storage intent settlement
 * @dev Covers createPI, processPIPath, security scenarios
 */
contract NexusSettlerTest is NexusSettlerTestBase {
    // ============================================================================
    // createPI Tests
    // ============================================================================

    function testCreatePI_Success() public {
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);

        vm.expectEmit(true, true, false, false);
        emit INexusSettler.PICreated(rootHash, user);

        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        assertTrue(nexusSettler.created(rootHash), "Should be created");
    }

    function testCreatePI_Duplicate() public {
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        vm.expectRevert(INexusSettler.IntentAlreadyExists.selector);
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);
    }

    function testCreatePI_InvalidCommitment() public {
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        INexusSettler.RootNode memory wrongRootNode =
            _createRootNode(keccak256("wrong"), keccak256("destination"), keccak256("offchain"));

        vm.expectRevert(INexusSettler.InvalidRootHash.selector);
        nexusSettler.createPI(rootHash, "", nonce, wrongRootNode);
    }

    function testCreatePI_InvalidSignature() public {
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));
        bytes memory invalidSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        nexusSettler.createPI(rootHash, invalidSig, nonce, rootNode);
    }

    // ============================================================================
    // processPIPath Tests
    // ============================================================================

    function testProcessPIPath_Success() public {
        uint256 nonce = 1;

        INexusSettler.IntendNode[] memory path = _createTestPath();
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        INexusSettler.TargetNode memory targetNode =
            _createSingleTargetNode(INexusSettler.TargetType.Source, uint16(block.chainid), entryNodeHash);

        bytes32 computedTargetHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode =
            _createRootNode(computedTargetHash, keccak256("destination"), keccak256("offchain"));
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, true);

        (bool isComplete,,) = nexusSettler.intentStates(_getCompletionKey(rootHash, computedTargetHash));
        assertTrue(isComplete, "Should complete");
    }

    function testProcessPIPath_InvalidChainId() public {
        uint256 nonce = 1;

        bytes32 targetNodeHash = _getTargetNodeHash(keccak256("temp"), true);
        INexusSettler.TargetNode memory targetNode = _createSingleTargetNode(
            INexusSettler.TargetType.Source,
            999, // Wrong chain ID
            targetNodeHash
        );

        bytes32 computedTargetHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode =
            _createRootNode(computedTargetHash, keccak256("destination"), keccak256("offchain"));
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        INexusSettler.IntendNode[] memory path = _createTestPath();

        vm.expectRevert(abi.encodeWithSelector(INexusSettler.ChainIdNotFound.selector, uint16(block.chainid)));
        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, true);
    }

    function testProcessPIPath_WrongTarget() public {
        uint256 nonce = 1;

        bytes32 wrongTargetHash = keccak256("wrong");
        INexusSettler.TargetNode memory targetNode =
            _createSingleTargetNode(INexusSettler.TargetType.Source, uint16(block.chainid), wrongTargetHash);

        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("different_source"), keccak256("destination"), keccak256("offchain"));
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        INexusSettler.IntendNode[] memory path = _createTestPath();

        vm.expectRevert(INexusSettler.InvalidTarget.selector);
        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, true);
    }

    function testProcessPIPath_AlreadyCompleted() public {
        uint256 nonce = 1;

        INexusSettler.IntendNode[] memory path = _createTestPath();
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        INexusSettler.TargetNode memory targetNode =
            _createSingleTargetNode(INexusSettler.TargetType.Source, uint16(block.chainid), entryNodeHash);

        bytes32 computedTargetHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode =
            _createRootNode(computedTargetHash, keccak256("destination"), keccak256("offchain"));
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, true);

        vm.expectRevert(INexusSettler.PathAlreadyProcessed.selector);
        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, true);
    }

    function testProcessPIPath_EmptyPath() public {
        uint256 nonce = 1;

        bytes32 targetNodeHash = _getTargetNodeHash(keccak256("temp"), true);
        INexusSettler.TargetNode memory targetNode =
            _createSingleTargetNode(INexusSettler.TargetType.Source, uint16(block.chainid), targetNodeHash);

        bytes32 computedTargetHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode =
            _createRootNode(computedTargetHash, keccak256("destination"), keccak256("offchain"));
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        INexusSettler.IntendNode[] memory emptyPath = new INexusSettler.IntendNode[](0);

        vm.expectRevert(INexusSettler.EmptyPath.selector);
        nexusSettler.processPIPath(rootHash, rootNode, targetNode, emptyPath, nonce, true);
    }
}
