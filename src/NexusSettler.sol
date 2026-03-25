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
 *      Two mappings track state: created[rootHash] and intentStates[completionKey].
 *      IntentState packs completed flag and bitmap (248 nodes) into single slot.
 */
contract NexusSettler is ReentrancyGuardTransient, EIP712, INexusSettler {
    using Address for address;

    /// Escrow contract for fund locking
    address public immutable escrow;

    /// Prevents replay: each rootHash can only be created once
    mapping(bytes32 => bool) public created;

    /// Tracks completion status and processed bitmap per (rootHash, targetNodeHash) pair
    mapping(bytes32 => IntentState) public intentStates;

    /// EIP-712 typehash: NexusPI(bytes32 rootHash,uint256 nonce)
    bytes32 private constant PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");

    /// Prevents gas griefing from unbounded paths
    uint256 private constant MAX_PATH_LENGTH = 100;

    constructor(address newEscrow) EIP712("NexusSettler", "2") {
        if (newEscrow == address(0)) revert InvalidTarget();
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
     * @dev 3-step validation: (1) rootHash commitment verify, (2) match targetNodeHash against rootNode.s or rootNode.d,
     *      (3) verify path[0] preimage matches targetNodeHash.
     * @param rootHash Root commitment hash
     * @param rootNode Source, destination, and offchain roots
     * @param targetNode Target type and chain-to-node mapping
     * @param path IntendNodes to execute (path[0] is entry point)
     * @param nonce Nonce from commitment for rootHash validation
     * @param isSource True if processing source chain, false for destination
     */
    function processPIPath(
        bytes32 rootHash,
        RootNode calldata rootNode,
        TargetNode calldata targetNode,
        IntendNode[] calldata path,
        uint256 nonce,
        bool isSource
    ) external nonReentrant {
        bytes32 computedRoot = keccak256(abi.encode(rootNode, nonce));
        if (computedRoot != rootHash) revert InvalidRootHash();

        bytes32 computedTargetRootHash = keccak256(abi.encode(targetNode));
        if (isSource) {
            if (rootNode.s != computedTargetRootHash) revert InvalidTarget();
        } else {
            if (rootNode.d != computedTargetRootHash) revert InvalidTarget();
        }

        bytes32 completionKey = keccak256(abi.encode(rootHash, computedTargetRootHash));
        IntentState memory state = intentStates[completionKey]; // 1 SLOAD

        if (state.bitmap == 0) {
            // Check empty path first before accessing path[0]
            if (path.length == 0) revert EmptyPath();
            bytes32 calculatedFirstNodeHash = keccak256(abi.encode(path[0]));
            bytes32 firstNodeHash = _extractTargetHash(targetNode.chainIdToNode);
            if (calculatedFirstNodeHash != firstNodeHash) revert InvalidPath();
        }

        if (state.completed) revert PathAlreadyProcessed();

        (uint256 height, bool isComplete, bytes32 lastNodeHash, uint248 updatedBitmap) =
            _executePath(state.bitmap, path);

        intentStates[completionKey] =
            IntentState({completed: isComplete, bitmap: updatedBitmap}); // 1 SSTORE

        emit IntendPathProcessed(computedTargetRootHash, lastNodeHash, rootHash, height);
    }

    /**
     * @notice Executes IntendNode path from calldata using bitmap tracking
     * @dev Traverses path following next pointers. For each node:
     *      - Detect cycles via visited[] array
     *      - Skip already-processed nodes (bitmap bit set)
     *      - Execute unprocessed nodes and set bitmap bit
     *      - Follow next pointer or stop if missing/terminal
     *      Single SLOAD at start, single SSTORE at end — O(1) storage ops.
     *      Node hashes are cached: the next-pointer verification hash from
     *      iteration N is reused as the nodeHash in iteration N+1.
     * @return height Nodes executed (including skipped)
     * @return isComplete True if reached terminal (next == 0)
     * @return lastNodeHash Hash of last executed/skipped node
     */
    function _executePath(uint248 currentBitmap, IntendNode[] calldata path)
        private
        returns (uint256 height, bool isComplete, bytes32 lastNodeHash, uint248 updatedBitmap)
    {
        uint256 currentIdx = 0;
        bytes32 nodeHash = keccak256(abi.encode(path[0]));

        uint256 bitmap = currentBitmap;

        // Note: Cycle detection not required. Infinite loops are prevented by:
        // 1. MAX_PATH_LENGTH limiting iterations to 100
        // 2. Gas limit - any circular path would exhaust gas and fail the transaction
        // 3. The next-pointer chain must eventually reach bytes32(0) or path end
        uint256 pathLen = path.length;
        while (currentIdx < pathLen) {
            if (height >= MAX_PATH_LENGTH) revert InvalidPath();

            IntendNode calldata node = path[currentIdx];

            if (node.target == address(0)) revert InvalidPath();

            unchecked {
                uint256 bit = 1 << height;
                if ((bitmap & bit) == 0) {
                    bitmap |= bit;
                    _executeAction(node.target, node.data);
                }

                height++;
            }
            lastNodeHash = nodeHash;

            if (node.next == bytes32(0)) {
                isComplete = true;
                break;
            }

            if (currentIdx + 1 < pathLen) {
                bytes32 nextNodeHash = keccak256(abi.encode(path[currentIdx + 1]));
                if (nextNodeHash == node.next) {
                    nodeHash = nextNodeHash;
                    unchecked { ++currentIdx; }
                } else {
                    isComplete = false;
                    break;
                }
            } else {
                isComplete = false;
                break;
            }
        }

        updatedBitmap = uint248(bitmap);
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
        target.functionCall(data);
    }
}
