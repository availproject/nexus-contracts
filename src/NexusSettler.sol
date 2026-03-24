// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {EIP712} from "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {INexusSettler} from "./interfaces/INexusSettler.sol";

/**
 * @title NexusSettler
 * @notice Zero-storage cross-chain intent settlement
 * @author Rachit Anand Srivastava (@privacy_prophet)
 * @dev All node data lives in calldata—only completion flags touch storage.
 *      Three mappings track state: created[rootHash], completed[completionKey],
 *      and processedNodes[nodeKey]. A 100-node path costs the same storage
 *      as 1 node (~75k gas total lifecycle).
 */
contract NexusSettler is ReentrancyGuardTransient, EIP712, INexusSettler {
    using Address for address;

    /// Escrow contract for fund locking
    address public immutable escrow;

    /// Prevents replay: each rootHash can only be created once
    mapping(bytes32 => bool) public created;

    /// Tracks which (rootHash, targetNodeHash) pairs finished execution
    mapping(bytes32 => bool) public completed;

    /// Tracks individual node execution to prevent re-execution
    mapping(bytes32 => bool) public processedNodes;

    /// EIP-712 typehash: NexusPI(bytes32 rootHash,uint256 nonce)
    bytes32 private constant PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");

    /// Prevents gas griefing from unbounded paths
    uint256 private constant MAX_PATH_LENGTH = 100;

    constructor(address newEscrow) EIP712("NexusSettler", "2") {
        require(newEscrow != address(0), "Invalid escrow");
        escrow = newEscrow;
    }

    /**
     * @notice Creates a signed Path Intent
     * @dev Verifies keccak256(rootNode, nonce) matches rootHash and signature is valid.
     *      The nonce ensures identical rootNode values produce unique rootHashes.
     * @param rootHash Commitment hash
     * @param signature EIP-712 signature of (rootHash, nonce)
     * @param nonce Unique nonce preventing rootHash collisions
     * @param rootNode Source, destination, and offchain roots
     */
    function createPI(bytes32 rootHash, bytes calldata signature, uint256 nonce, RootNode calldata rootNode)
        external
        nonReentrant
    {
        if (created[rootHash]) revert IntentAlreadyExists();

        bytes32 computedRoot = keccak256(abi.encode(rootNode, nonce));
        if (computedRoot != rootHash) revert InvalidRootHash();

        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, signature);

        if (signer == address(0)) revert InvalidSignature();

        created[rootHash] = true;
        emit PICreated(rootHash, signer);
    }

    /**
     * @notice Executes path with chain ID validation and preimage verification
     * @dev 5-step validation: (1) created check, (2) commitment verify,
     *      (3) extract target for current chain, (4) match targetNodeHash,
     *      (5) verify path[0] preimage matches targetNodeHash.
     * @param rootHash Root commitment hash
     * @param targetNodeHash Must match extracted target from chainIdToNode
     * @param path IntendNodes to execute (path[0] is entry point)
     * @param targetNode Target type and chain-to-node mapping
     * @param rootNode Source, destination, and offchain roots
     * @param nonce Nonce from commitment
     */
    function processPIPath(
        bytes32 rootHash,
        bytes32 targetNodeHash,
        IntendNode[] calldata path,
        TargetNode calldata targetNode,
        RootNode calldata rootNode,
        uint256 nonce
    ) external nonReentrant {
        if (!created[rootHash]) revert IntentAlreadyExists();

        bytes32 computedRoot = keccak256(abi.encode(rootNode, nonce));
        if (computedRoot != rootHash) revert InvalidRootHash();

        bytes32 computedTargetRootHash = keccak256(abi.encode(targetNode));
        if (targetNodeHash != computedTargetRootHash) revert InvalidTarget();

        bytes32 completionKey = keccak256(abi.encode(rootHash, targetNodeHash));
        bool isFirstCall = !processedNodes[keccak256(abi.encode(completionKey, "first"))];

        if (isFirstCall) {
            if (path.length == 0) revert EmptyPath();
            bytes32 calculatedFirstNodeHash = keccak256(abi.encode(path[0]));
            bytes32 firstNodeHash = _extractTargetHash(targetNode.chainIdToNode);
            if (calculatedFirstNodeHash != firstNodeHash) revert InvalidPath();
        }

        if (completed[completionKey]) revert PathAlreadyProcessed();
        if (path.length == 0) revert EmptyPath();

        (uint256 height, bool isComplete, bytes32 lastNodeHash) = _executePath(rootHash, targetNodeHash, path);

        if (isComplete) {
            completed[completionKey] = true;
        }

        emit IntendPathProcessed(targetNodeHash, lastNodeHash, rootHash, height);
    }

    /**
     * @notice Executes IntendNode path from calldata
     * @dev Traverses path following next pointers. For each node:
     *      - Detect cycles via visited[] array
     *      - Skip already-processed nodes (emit IntendNodeSkipped)
     *      - Execute unprocessed nodes (emit IntendNodeExec)
     *      - Follow next pointer or stop if missing/terminal
     * @return height Nodes executed (including skipped)
     * @return isComplete True if reached terminal (next == 0)
     * @return lastNodeHash Hash of last executed/skipped node
     */
    function _executePath(bytes32 rootHash, bytes32 targetNodeHash, IntendNode[] calldata path)
        private
        returns (uint256 height, bool isComplete, bytes32 lastNodeHash)
    {
        uint256 currentIdx = 0;
        bytes32[MAX_PATH_LENGTH] memory visited;

        while (currentIdx < path.length) {
            if (height >= MAX_PATH_LENGTH) revert InvalidPath();

            IntendNode calldata node = path[currentIdx];

            bytes32 nodeHash = keccak256(abi.encode(node));
            for (uint256 i = 0; i < height; i++) {
                if (visited[i] == nodeHash) revert CycleDetected();
            }
            visited[height] = nodeHash;

            if (node.target == address(0)) revert InvalidPath();

            bytes32 nodeKey = keccak256(abi.encode(rootHash, targetNodeHash, nodeHash));

            if (processedNodes[nodeKey]) {
                emit IntendNodeSkipped(nodeHash, height);
            } else {
                processedNodes[nodeKey] = true;
                emit IntendNodeExec(nodeHash, height);
                _executeAction(node.target, node.data);
            }

            height++;
            lastNodeHash = nodeHash;

            if (node.next == bytes32(0)) {
                isComplete = true;
                break;
            }

            if (currentIdx + 1 < path.length) {
                if (keccak256(abi.encode(path[currentIdx + 1])) == node.next) {
                    currentIdx = currentIdx + 1;
                } else {
                    isComplete = false;
                    break;
                }
            } else {
                isComplete = false;
                break;
            }
        }
    }

    /**
     * @notice Extracts target hash using seed-based perfect hash lookup
     * @dev Data format: <k:2><seed:2><chainId_0:2><hash_0:32>...<chainId_{k-1}:2><hash_{k-1}:32>
     *      Each slot = 34 bytes. Off-chain encoder picks k and seed so
     *      keccak256(chainId, seed) % k gives collision-free slots.
     * @param data Perfect hash table bytes
     * @return targetHash 32-byte hash for current chain
     */
    function _extractTargetHash(bytes calldata data) internal view returns (bytes32) {
        if (data.length < 38) revert InvalidTargetFormat();

        uint16 k;
        uint16 seed;
        assembly {
            let header := calldataload(data.offset)
            k := shr(240, header)
            seed := shr(240, shl(16, header))
        }

        if (k == 0 || data.length != uint256(4) + uint256(k) * 34) revert InvalidTargetFormat();

        uint256 slot = uint256(keccak256(abi.encodePacked(uint16(block.chainid), seed))) % k;
        uint256 entryPos = 4 + slot * 34;

        uint16 entryChainId;
        bytes32 targetHash;
        assembly {
            let word := calldataload(add(data.offset, entryPos))
            entryChainId := shr(240, word)
            targetHash := calldataload(add(data.offset, add(entryPos, 2)))
        }

        if (entryChainId != uint16(block.chainid)) revert ChainIdNotFound(uint16(block.chainid));

        return targetHash;
    }

    /**
     * @notice Executes low-level call at target address
     * @dev Reverts on failure, bubbling up as InvalidPath.
     * @param target Contract address
     * @param data Calldata
     */
    function _executeAction(address target, bytes calldata data) private {
        (bool success,) = target.call(data);
        if (!success) revert InvalidPath();
    }
}
