// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/**
 * @title INexusSettler
 * @notice Zero-storage DAG-based intent settlement interface
 * @dev Node data stays in calldata—only completion status hits storage.
 */
interface INexusSettler {
    /// Kept for IActionRouter compatibility
    enum ActionType {
        PERMIT,
        PERMIT2,
        TRANSFER,
        BRIDGE,
        SWAP,
        BRIDGE_AND_SWAP
    }

    /// Kept for IActionRouter compatibility
    struct Action {
        ActionType actionType;
        string target;
        bytes callData;
        uint256 value;
    }

    /**
     * @notice Execution node data
     * @dev Lives in calldata, never stored.
     * @param next Index of next node (0 if terminal)
     * @param target Contract to call
     * @param data Calldata
     */
    struct IntendNode {
        bytes32 next;
        address target;
        bytes data;
    }

    /// Root node containing source, destination, and offchain intent roots
    struct RootNode {
        bytes32 s; // source root
        bytes32 d; // destination root
        bytes32 o; // offchain intents root
    }

    /// Target type for distinguishing source vs destination
    enum TargetType {
        Source,
        Destination
    }

    /// Target node with type and chain-to-node mapping
    struct TargetNode {
        TargetType targetType;
        bytes chainIdToNode; // <k:2><seed:2><chainId_0:2><hash_0:32>...
    }

    error InvalidSignature();
    error IntentAlreadyExists();
    error PathAlreadyProcessed();
    error InvalidRootHash();
    error InvalidPath();
    error EmptyPath();
    error CycleDetected();

    /**
     * @notice Chain ID mismatch in target data
     * @param expected Current chain ID
     * @param actual Chain ID found in data
     */
    error InvalidChainId(uint16 expected, uint16 actual);

    /// Chain ID lookup miss in perfect hash table
    error ChainIdNotFound(uint16 chainId);

    error InvalidTargetFormat();
    error InvalidTarget();

    /**
     * @notice Intent created
     * @param rootHash Commitment hash
     * @param signer Address that signed
     */
    event PICreated(bytes32 indexed rootHash, address indexed signer);

    /**
     * @notice Node executed
     * @param nodeHash Hash of executed node
     * @param level Depth in path (0-indexed)
     */
    event IntendNodeExec(bytes32 indexed nodeHash, uint256 level);

    /**
     * @notice Node skipped (already processed)
     * @param nodeHash Hash of skipped node
     * @param level Depth in path (0-indexed)
     */
    event IntendNodeSkipped(bytes32 indexed nodeHash, uint256 level);

    /**
     * @notice Path processed (complete or partial)
     * @param targetNodeHash Entry point hash
     * @param lastNodeHash Final node executed
     * @param graphRoot Root hash of intent
     * @param height Nodes executed
     */
    event IntendPathProcessed(bytes32 indexed targetNodeHash, bytes32 lastNodeHash, bytes32 graphRoot, uint256 height);

    /**
     * @notice Creates a signed Path Intent
     * @dev Verifies keccak256(rootNode, nonce) == rootHash.
     * @param rootHash Commitment hash
     * @param signature EIP-712 signature of (rootHash, nonce)
     * @param nonce Prevents collision between identical rootNode values
     * @param rootNode Source, destination, and offchain roots
     */
    function createPI(bytes32 rootHash, bytes calldata signature, uint256 nonce, RootNode calldata rootNode) external;

    /**
     * @notice Executes path with chain ID validation
     * @dev Uses path[0] as entry node. Validates chain ID from targetNode.chainIdToNode
     *      matches current chain, then verifies targetNodeHash and executes path.
     * @param rootHash Root commitment
     * @param targetNodeHash Must match extracted target from chainIdToNode
     * @param path IntendNodes to execute (path[0] is entry node)
     * @param targetNode Target type and chain-to-node mapping
     * @param rootNode Source, destination, and offchain roots
     * @param nonce From commitment
     */
    function processPIPath(
        bytes32 rootHash,
        bytes32 targetNodeHash,
        IntendNode[] calldata path,
        TargetNode calldata targetNode,
        RootNode calldata rootNode,
        uint256 nonce
    ) external;

    /// Returns true if rootHash was created
    function created(bytes32 rootHash) external view returns (bool);

    /// Returns true if (rootHash, targetNodeHash) completed
    function completed(bytes32 completionKey) external view returns (bool);

    /// Returns true if IntendNode was processed
    function processedNodes(bytes32 nodeKey) external view returns (bool);
}
