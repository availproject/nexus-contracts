// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "../src/NexusSettler.sol";

/**
 * @title NexusSettlerTest
 * @notice Tests for zero-storage intent settlement
 * @dev Covers createPI, processPIPath, security scenarios, gas benchmarks
 */
contract NexusSettlerTest is Test {
    NexusSettler public nexusSettler;
    address public escrow;
    address public user;
    uint256 public userPrivateKey;

    function setUp() public {
        escrow = makeAddr("escrow");
        (user, userPrivateKey) = makeAddrAndKey("user");
        nexusSettler = new NexusSettler(escrow);
    }

    /// Computes EIP-712 digest for signing
    function _computeDigest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NexusSettler")),
                keccak256(bytes("2")),
                block.chainid,
                address(nexusSettler)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// Creates single-node test path
    function _createTestPath() internal pure returns (INexusSettler.IntendNode[] memory) {
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0), target: address(0x1234), data: abi.encodeWithSignature("dummy()")
        });
        return path;
    }

    /// Creates multi-node path with linked next pointers
    function _createMultiNodePath(uint256 count) internal pure returns (INexusSettler.IntendNode[] memory) {
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](count);
        for (uint256 i = 0; i < count; i++) {
            path[i] = INexusSettler.IntendNode({
                next: i + 1 < count ? keccak256(abi.encode(path[i + 1])) : bytes32(0),
                target: address(uint160(0x1000 + i)),
                data: abi.encodeWithSignature("action%i()", i)
            });
        }
        return path;
    }

    /// Helper to build RootNode
    function _createRootNode(bytes32 s, bytes32 d, bytes32 o) internal pure returns (INexusSettler.RootNode memory) {
        return INexusSettler.RootNode({s: s, d: d, o: o});
    }

    /// Helper to build TargetNode with perfect hash data
    function _createTargetNode(INexusSettler.TargetType targetType, uint16[] memory chainIds, bytes32[] memory hashes)
        internal
        pure
        returns (INexusSettler.TargetNode memory)
    {
        require(chainIds.length == hashes.length, "length mismatch");
        uint16 k = uint16(chainIds.length);

        // Find collision-free seed
        uint16 seed;
        bool found;
        for (uint16 s = 0; s < 65535; s++) {
            bool collision = false;
            for (uint256 i = 0; i < k && !collision; i++) {
                uint256 slotI = uint256(keccak256(abi.encodePacked(chainIds[i], s))) % k;
                for (uint256 j = i + 1; j < k && !collision; j++) {
                    uint256 slotJ = uint256(keccak256(abi.encodePacked(chainIds[j], s))) % k;
                    if (slotI == slotJ) collision = true;
                }
            }
            if (!collision) {
                seed = s;
                found = true;
                break;
            }
        }
        require(found, "no valid seed found");

        // Build perfect hash table
        bytes memory chainIdToNode = new bytes(4 + uint256(k) * 34);
        chainIdToNode[0] = bytes1(uint8(k >> 8));
        chainIdToNode[1] = bytes1(uint8(k));
        chainIdToNode[2] = bytes1(uint8(seed >> 8));
        chainIdToNode[3] = bytes1(uint8(seed));

        for (uint256 i = 0; i < k; i++) {
            uint256 slot = uint256(keccak256(abi.encodePacked(chainIds[i], seed))) % k;
            uint256 pos = 4 + slot * 34;
            chainIdToNode[pos] = bytes1(uint8(chainIds[i] >> 8));
            chainIdToNode[pos + 1] = bytes1(uint8(chainIds[i]));
            for (uint256 b = 0; b < 32; b++) {
                chainIdToNode[pos + 2 + b] = hashes[i][b];
            }
        }

        return INexusSettler.TargetNode({targetType: targetType, chainIdToNode: chainIdToNode});
    }

    /// Creates single-chain TargetNode (k=1)
    function _createSingleTargetNode(INexusSettler.TargetType targetType, uint16 chainId, bytes32 targetHash)
        internal
        pure
        returns (INexusSettler.TargetNode memory)
    {
        uint16[] memory chainIds = new uint16[](1);
        chainIds[0] = chainId;
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = targetHash;
        return _createTargetNode(targetType, chainIds, hashes);
    }

    /// Computes target node hash for testing
    function _getTargetNodeHash(bytes32 rootHash, bool isSource) internal pure returns (bytes32) {
        return isSource ? keccak256(abi.encode(rootHash, "source")) : keccak256(abi.encode(rootHash, "destination"));
    }

    /// Computes completion key for testing
    function _getCompletionKey(bytes32 rootHash, bytes32 targetNodeHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(rootHash, targetNodeHash));
    }

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
        // Create RootNode and intent
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        // Create TargetNode for source (path[0] will be entry node)
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        INexusSettler.TargetNode memory targetNode =
            _createSingleTargetNode(INexusSettler.TargetType.Source, uint16(block.chainid), targetNodeHash);

        // Create path - path[0] is entry node
        INexusSettler.IntendNode[] memory path = _createTestPath();

        // Execute with validation
        nexusSettler.processPIPath(rootHash, targetNodeHash, path, targetNode, rootNode, nonce);

        assertTrue(nexusSettler.completed(_getCompletionKey(rootHash, targetNodeHash)), "Should complete");
    }

    function testProcessPIPath_InvalidChainId() public {
        // Create RootNode and intent
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        // Create TargetNode with WRONG chain ID
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        INexusSettler.TargetNode memory targetNode = _createSingleTargetNode(
            INexusSettler.TargetType.Source,
            999, // Wrong chain ID
            targetNodeHash
        );

        INexusSettler.IntendNode[] memory path = _createTestPath();

        // Should revert with ChainIdNotFound
        vm.expectRevert(abi.encodeWithSelector(INexusSettler.ChainIdNotFound.selector, uint16(block.chainid)));
        nexusSettler.processPIPath(rootHash, targetNodeHash, path, targetNode, rootNode, nonce);
    }

    function testProcessPIPath_WrongTarget() public {
        // Create RootNode and intent
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        // Create TargetNode with correct chain ID but WRONG target hash
        bytes32 wrongTargetHash = keccak256("wrong");
        INexusSettler.TargetNode memory targetNode =
            _createSingleTargetNode(INexusSettler.TargetType.Source, uint16(block.chainid), wrongTargetHash);

        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        INexusSettler.IntendNode[] memory path = _createTestPath();

        // Should revert with InvalidTarget
        vm.expectRevert(INexusSettler.InvalidTarget.selector);
        nexusSettler.processPIPath(rootHash, targetNodeHash, path, targetNode, rootNode, nonce);
    }

    function testProcessPIPath_AlreadyCompleted() public {
        // Create RootNode and intent
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        // Create TargetNode and execute once
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        INexusSettler.TargetNode memory targetNode =
            _createSingleTargetNode(INexusSettler.TargetType.Source, uint16(block.chainid), targetNodeHash);

        INexusSettler.IntendNode[] memory path = _createTestPath();
        nexusSettler.processPIPath(rootHash, targetNodeHash, path, targetNode, rootNode, nonce);

        // Second call should revert
        vm.expectRevert(INexusSettler.PathAlreadyProcessed.selector);
        nexusSettler.processPIPath(rootHash, targetNodeHash, path, targetNode, rootNode, nonce);
    }

    function testProcessPIPath_EmptyPath() public {
        // Create RootNode and intent
        INexusSettler.RootNode memory rootNode =
            _createRootNode(keccak256("source"), keccak256("destination"), keccak256("offchain"));
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash =
            keccak256(abi.encode(keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"), rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, rootNode);

        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        INexusSettler.TargetNode memory targetNode =
            _createSingleTargetNode(INexusSettler.TargetType.Source, uint16(block.chainid), targetNodeHash);

        INexusSettler.IntendNode[] memory emptyPath = new INexusSettler.IntendNode[](0);

        vm.expectRevert(INexusSettler.EmptyPath.selector);
        nexusSettler.processPIPath(rootHash, targetNodeHash, emptyPath, targetNode, rootNode, nonce);
    }
}
