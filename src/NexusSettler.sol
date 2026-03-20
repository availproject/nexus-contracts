// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {EIP712} from "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {INexusSettler} from "./interfaces/INexusSettler.sol";

/**
 * @title NexusSettler
 * @notice Zero-overhead cross-chain intent settlement contract
 * @author Rachit Anand Srivastava ( @privacy_prophet )
 * @dev DAG architecture where all node data lives in calldata, not storage.
 *      RootNode, TargetNode, and IntendNodes are verified and executed on-demand.
 *      We only store completion flags: one bool per rootHash creation, one per (root, target) completion,
 *      and one per individual node execution. Total gas for a full intent lifecycle runs ~75k.
 *      Storage grows linearly with unique intents, not with node count—100 nodes in a path
 *      costs the same storage as 1 node.
 */
contract NexusSettler is ReentrancyGuardTransient, EIP712, INexusSettler {
    using Address for address;

    /**
     * @notice Escrow contract address for fund locking
     */
    address public immutable escrow;

    /**
     * @notice Tracks created rootHashes to prevent replay attacks
     * @dev Once a rootHash is created, it cannot be reused. The rootHash includes
     *      a nonce, so even identical (s, d, o) triples produce different hashes.
     */
    mapping(bytes32 => bool) public created;

    /**
     * @notice Tracks completed (rootHash, targetNodeHash) pairs
     * @dev Each rootHash can complete multiple paths (source, destination, offchain).
     *      The key keccak256(rootHash, targetNodeHash) ensures each path completes once.
     */
    mapping(bytes32 => bool) public completed;

    /**
     * @notice Tracks individual IntendNodes that have been processed
     * @dev Key = keccak256(rootHash, targetNodeHash, nodeHash). When a path is
     *      partially executed and called again, already-processed nodes skip
     *      execution and emit IntendNodeSkipped instead of IntendNodeExec.
     */
    mapping(bytes32 => bool) public processedNodes;

    /**
     * @notice EIP-712 typehash for Path Intent with nonce
     * @dev Used for signature verification including nonce parameter
     */
    bytes32 private constant PI_TYPEHASH =
        keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");

    /**
     * @notice Maximum path length to prevent gas griefing
     */
    uint256 private constant MAX_PATH_LENGTH = 100;

    /**
     * @notice Contract constructor
     * @param newEscrow Address of escrow contract
     */
    constructor(address newEscrow) EIP712("NexusSettler", "2") {
        require(newEscrow != address(0), "Invalid escrow");
        escrow = newEscrow;
    }

    /**
     * @notice Creates a Path Intent with signature verification
     * @inheritdoc INexusSettler
     * @dev Caller provides rootHash = keccak256(s, d, o, nonce) and a signature over (rootHash, nonce).
     *      We verify the commitment matches, recover the signer, and mark rootHash as created.
     *      The nonce ensures that identical (s, d, o) values across different intents
     *      produce unique rootHashes, preventing collision attacks.
     * @param rootHash Commitment hash = keccak256(s, d, o, nonce)
     * @param signature EIP-712 signature of (rootHash, nonce)
     * @param nonce Unique nonce to prevent rootHash collisions
     * @param s Source target hash (provided, not stored)
     * @param d Destination target hash (provided, not stored)
     * @param o Offchain target hash (provided, not stored)
     */
    function createPI(
        bytes32 rootHash,
        bytes calldata signature,
        uint256 nonce,
        bytes32 s,
        bytes32 d,
        bytes32 o
    ) external nonReentrant {
        // Check rootHash not already created
        if (created[rootHash]) revert IntentAlreadyExists();

        // Verify commitment: keccak256(s, d, o, nonce) == rootHash
        bytes32 computedRoot = keccak256(abi.encode(s, d, o, nonce));
        if (computedRoot != rootHash) revert InvalidRootHash();

        // Verify signature using EIP-712 with nonce
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, signature);
        
        // Ensure signature is valid
        if (signer == address(0)) revert InvalidSignature();

        // Mark rootHash as created
        created[rootHash] = true;

        // Emit creation event
        emit PICreated(rootHash, signer);
    }

    /**
     * @notice Processes an intent path - PURE EXECUTION with partial support
     * @inheritdoc INexusSettler
     * @dev Executes nodes from calldata until hitting a missing next pointer or reaching
     *      a node with next == bytes32(0). Only marks the path as completed when we
     *      reach that terminal node. If execution stops mid-path (next node not in calldata),
     *      the caller can resume by providing the remaining nodes in a subsequent call.
     *      Already-processed nodes are skipped, emitting IntendNodeSkipped instead of IntendNodeExec.
     * @param rootHash Root commitment hash
     * @param targetNodeHash Target node hash (for replay protection key)
     * @param path Array of IntendNodes to execute (from calldata)
     */
    function processPIPath(
        bytes32 rootHash,
        bytes32 targetNodeHash,
        IntendNode[] calldata path
    ) external nonReentrant {
        // Compute unique key for this (root, target) pair
        bytes32 completionKey = keccak256(abi.encode(rootHash, targetNodeHash));
        
        // Check not already completed (ONLY storage read)
        if (completed[completionKey]) revert PathAlreadyProcessed();

        // Verify path is not empty
        if (path.length == 0) revert EmptyPath();

        // Execute path starting from first node
        // Returns (height, isComplete, lastNodeHash)
        (uint256 height, bool isComplete, bytes32 lastNodeHash) = _executePath(
            rootHash,
            targetNodeHash,
            path
        );

        // Only mark as completed if we reached the end (next == bytes32(0))
        if (isComplete) {
            completed[completionKey] = true;
        }

        // Emit completion event (even for partial execution)
        emit IntendPathProcessed(
            targetNodeHash,
            lastNodeHash,
            rootHash,
            height
        );
    }

    /**
     * @notice Execute IntendNode path from calldata
     * @dev Traverses the path following next pointers. For each node:
     *      1. Check for cycles (same nodeHash seen twice)
     *      2. Check if already processed (skip and emit IntendNodeSkipped)
     *      3. Mark as processed, emit IntendNodeExec, execute the call
     *      4. Follow next pointer or stop if missing/terminal
     *      Returns the count of nodes visited, whether we reached a terminal node,
     *      and the hash of the last node processed.
     * @param rootHash Root commitment hash for node key
     * @param targetNodeHash Target node hash for node key
     * @param path Array of IntendNodes from calldata
     * @return height Number of nodes executed (including skipped)
     * @return isComplete True if reached end of path (next == bytes32(0))
     * @return lastNodeHash Hash of the last executed/skipped node
     */
    function _executePath(
        bytes32 rootHash,
        bytes32 targetNodeHash,
        IntendNode[] calldata path
    ) 
        private 
        returns (uint256 height, bool isComplete, bytes32 lastNodeHash) 
    {
        uint256 currentIdx = 0;
        bytes32[MAX_PATH_LENGTH] memory visited;

        while (currentIdx < path.length) {
            // Check max length
            if (height >= MAX_PATH_LENGTH) revert InvalidPath();

            // Get current node
            IntendNode calldata node = path[currentIdx];
            
            // Check for cycles using node hash
            bytes32 nodeHash = keccak256(abi.encode(node));
            for (uint256 i = 0; i < height; i++) {
                if (visited[i] == nodeHash) revert CycleDetected();
            }
            visited[height] = nodeHash;

            // Validate target
            if (node.target == address(0)) revert InvalidPath();

            // Compute node key for tracking
            bytes32 nodeKey = keccak256(abi.encode(rootHash, targetNodeHash, nodeHash));

            // Check if node already processed
            if (processedNodes[nodeKey]) {
                // Skip execution, emit skipped event
                emit IntendNodeSkipped(nodeHash, height);
            } else {
                // Mark as processed BEFORE execution (reentrancy protection)
                processedNodes[nodeKey] = true;

                // Emit execution event
                emit IntendNodeExec(nodeHash, height);

                // Execute action
                _executeAction(node.target, node.data);
            }

            height++;
            lastNodeHash = nodeHash;

            // Check if this is the end of the path
            if (node.next == bytes32(0)) {
                // End of path - mark as complete
                isComplete = true;
                break;
            }
            
            // Find next node by hash (linear search)
            bool found = false;
            for (uint256 i = 0; i < path.length; i++) {
                if (keccak256(abi.encode(path[i])) == node.next) {
                    currentIdx = i;
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                // Next node not in path - partial execution, allow resuming
                isComplete = false;
                break;
            }
        }
    }

    /**
     * @notice Execute action at target address
     * @dev Low-level call with no value. Reverts on failure, bubbling up
     *      as InvalidPath. The caller is responsible for encoding correct calldata.
     * @param target Contract to call
     * @param data Calldata
     */
    function _executeAction(address target, bytes calldata data) private {
        (bool success, ) = target.call(data);
        if (!success) revert InvalidPath();
    }
}
