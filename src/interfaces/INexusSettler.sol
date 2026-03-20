// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/**
 * @title INexusSettler
 * @notice Interface for zero-storage DAG-based intent settlement
 * @dev All node data provided in calldata, only completion status stored
 */
interface INexusSettler {
    /**
     * @notice Action type enumeration for backward compatibility
     * @dev Kept for IActionRouter compatibility
     */
    enum ActionType {
        PERMIT,
        PERMIT2,
        TRANSFER,
        BRIDGE,
        SWAP,
        BRIDGE_AND_SWAP
    }

    /**
     * @notice Action struct for backward compatibility
     * @dev Kept for IActionRouter compatibility
     */
    struct Action {
        ActionType actionType;
        string target;
        bytes callData;
        uint256 value;
    }

    /**
     * @notice IntendNode struct - execution node data
     * @dev Provided in calldata, never stored on-chain
     * @param next Index of next node in path (0 if end)
     * @param target Contract address to call
     * @param data Calldata to execute
     */
    struct IntendNode {
        bytes32 next;
        address target;
        bytes data;
    }

    /**
     * @notice Invalid signature provided
     */
    error InvalidSignature();

    /**
     * @notice Intent already exists (root hash already used)
     */
    error IntentAlreadyExists();

    /**
     * @notice Path already processed for this root and target type
     */
    error PathAlreadyProcessed();

    /**
     * @notice Invalid root hash (commitment mismatch)
     */
    error InvalidRootHash();

    /**
     * @notice Invalid path structure
     */
    error InvalidPath();

    /**
     * @notice Empty path (no nodes to execute)
     */
    error EmptyPath();

    /**
     * @notice Cycle detected in path
     */
    error CycleDetected();

    /**
     * @notice Emitted when a new Path Intent is created
     * @param rootHash The root hash of the created intent
     * @param signer The address that signed the intent
     */
    event PICreated(bytes32 indexed rootHash, address indexed signer);

    /**
     * @notice Emitted when an IntendNode is executed
     * @param nodeHash Hash of the executed node
     * @param level Depth level in the path (0-indexed)
     */
    event IntendNodeExec(bytes32 indexed nodeHash, uint256 level);

    /**
     * @notice Emitted when an IntendNode is skipped (already processed)
     * @param nodeHash Hash of the skipped node
     * @param level Depth level in the path (0-indexed)
     */
    event IntendNodeSkipped(bytes32 indexed nodeHash, uint256 level);

    /**
     * @notice Emitted when a complete intent path is processed
     * @param targetNodeHash Hash of the target that initiated the path
     * @param lastNodeHash Hash of the final node executed
     * @param graphRoot Root hash of the entire intent
     * @param height Number of nodes executed in the path
     */
    event IntendPathProcessed(
        bytes32 indexed targetNodeHash,
        bytes32 lastNodeHash,
        bytes32 graphRoot,
        uint256 height
    );

    /**
     * @notice Creates a Path Intent with signature verification
     * @dev Verifies commitment and signature, stores NOTHING
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
    ) external;

    /**
     * @notice Processes an intent path - PURE EXECUTION with partial support
     * @dev Executes path from calldata, marks completion ONLY when reaching end
     *      Partial execution: stops if next node not found, allows resuming
     *      Node tracking: skips already-processed nodes, prevents re-execution
     *      Source of truth for completion: IntendNode has next == bytes32(0)
     * @param rootHash Root commitment hash
     * @param targetNodeHash Target node hash (for replay protection key)
     * @param path Array of IntendNodes to execute (from calldata)
     */
    function processPIPath(
        bytes32 rootHash,
        bytes32 targetNodeHash,
        IntendNode[] calldata path
    ) external;

    /**
     * @notice Check if a rootHash has been created
     * @param rootHash The root hash to check
     * @return created True if the intent has been created
     */
    function created(bytes32 rootHash) external view returns (bool);

    /**
     * @notice Check if a (rootHash, targetNodeHash) pair has been completed
     * @param completionKey The keccak256(rootHash, targetNodeHash) key
     * @return completed True if the path has been executed
     */
    function completed(bytes32 completionKey) external view returns (bool);

    /**
     * @notice Check if a specific IntendNode has been processed
     * @param nodeKey The keccak256(rootHash, targetNodeHash, nodeHash) key
     * @return processed True if the node has been executed
     */
    function processedNodes(bytes32 nodeKey) external view returns (bool);
}
