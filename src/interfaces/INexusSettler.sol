// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/**
 * @title INexusSettler
 * @notice Zero-storage DAG-based intent settlement interface
 * @dev Node data stays in calldata—only completion status hits storage.
 */
interface INexusSettler {
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

    /// @notice Packed intent state per completion key
    /// @dev Uses uint248 for bitmap to pack with bool in single slot
    struct IntentState {
        bool completed;
        uint248 bitmap;
    }

    error InvalidSignature();
    error IntentAlreadyExists();
    error PathAlreadyProcessed();
    error InvalidRootHash();
    error InvalidPath();
    error EmptyPath();

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
     * @notice Executes path settlement for a specific target node
     * @dev Validates rootHash exists, matches targetNodeHash against rootNode.s or rootNode.d,
     *      then executes the path with bitmap tracking for resumability.
     * @param rootHash Root commitment
     * @param rootNode Source, destination, and offchain roots
     * @param targetNode Target type and chain-to-node mapping
     * @param path IntendNodes to execute (path[0] is entry node)
     * @param nonce From commitment
     * @param isSource True if processing source chain, false for destination
     */
    function processPIPath(
        bytes32 rootHash,
        RootNode calldata rootNode,
        TargetNode calldata targetNode,
        IntendNode[] calldata path,
        uint256 nonce,
        bool isSource
    ) external;

    /// Returns true if rootHash was created
    function created(bytes32 rootHash) external view returns (bool);

    /// Returns intent state for a completion key
    /// @return completed Whether the path is complete
    /// @return bitmap Processed node bitmap (248 bits)
    function intentStates(bytes32 completionKey) external view returns (bool completed, uint248 bitmap);
}
