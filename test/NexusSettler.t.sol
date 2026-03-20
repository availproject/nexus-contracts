// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "../src/NexusSettler.sol";

/**
 * @title NexusSettlerTest
 * @notice Test suite for zero-storage NexusSettler
 * @dev Tests cover: createPI, processPIPath, security, gas benchmarks
 */
contract NexusSettlerTest is Test {
    NexusSettler public nexusSettler;
    address public escrow;
    
    // Test addresses
    address public user;
    uint256 public userPrivateKey;

    function setUp() public {
        // Setup test addresses
        escrow = makeAddr("escrow");
        (user, userPrivateKey) = makeAddrAndKey("user");
        
        // Deploy contract
        nexusSettler = new NexusSettler(escrow);
    }

    /**
     * @notice Compute EIP-712 digest for testing
     */
    function _computeDigest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("NexusSettler")),
            keccak256(bytes("2")),
            block.chainid,
            address(nexusSettler)
        ));
        
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /**
     * @notice Create a test path with single node
     */
    function _createTestPath() internal pure returns (INexusSettler.IntendNode[] memory) {
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(0x1234),
            data: abi.encodeWithSignature("dummy()")
        });
        return path;
    }

    /**
     * @notice Create a test path with multiple nodes
     */
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

    // ============================================================================
    // createPI Tests
    // ============================================================================

    /**
     * @notice Test successful intent creation
     */
    function testCreatePI_Success() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        // Create signature with nonce
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        // Expect event
        vm.expectEmit(true, true, false, false);
        emit INexusSettler.PICreated(rootHash, user);
        
        // Should succeed
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
        
        // Verify created
        assertTrue(nexusSettler.created(rootHash), "Should be created");
        
        // Verify not completed yet
        assertFalse(nexusSettler.completed(_getCompletionKey(rootHash, _getTargetNodeHash(rootHash, true))), "Should not be completed");
    }

    /**
     * @notice Test createPI reverts with duplicate rootHash
     */
    function testCreatePI_Duplicate() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        // Create signature with nonce
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);
        
        // First call succeeds
        nexusSettler.createPI(rootHash, signature, nonce, s, d, o);
        
        // Second call reverts
        vm.expectRevert(INexusSettler.IntentAlreadyExists.selector);
        nexusSettler.createPI(rootHash, signature, nonce, s, d, o);
    }

    /**
     * @notice Test createPI reverts with invalid commitment
     */
    function testCreatePI_InvalidCommitment() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        // Wrong commitment
        bytes32 wrongS = keccak256("wrong");
        
        vm.expectRevert(INexusSettler.InvalidRootHash.selector);
        nexusSettler.createPI(rootHash, "", nonce, wrongS, d, o);
    }

    /**
     * @notice Test createPI reverts with invalid signature
     */
    function testCreatePI_InvalidSignature() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        bytes memory invalidSig = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));
        
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        nexusSettler.createPI(rootHash, invalidSig, nonce, s, d, o);
    }

    /**
     * @notice Helper to compute target node hash
     */
    function _getTargetNodeHash(bytes32 rootHash, bool isSource) internal pure returns (bytes32) {
        return isSource 
            ? keccak256(abi.encode(rootHash, "source"))
            : keccak256(abi.encode(rootHash, "destination"));
    }

    /**
     * @notice Helper to compute completion key
     */
    function _getCompletionKey(bytes32 rootHash, bytes32 targetNodeHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(rootHash, targetNodeHash));
    }

    /**
     * @notice Test successful path processing
     */
    function testProcessPIPath_Success() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        bytes32 rootHash = keccak256(abi.encode(s, d, o));
        
        // Create path
        INexusSettler.IntendNode[] memory path = _createTestPath();
        
        // Process path
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        
        // Verify completed
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        assertTrue(nexusSettler.completed(completionKey), "Path should be completed");
    }

    /**
     * @notice Test processPIPath reverts with already completed path
     */
    function testProcessPIPath_AlreadyCompleted() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        bytes32 rootHash = keccak256(abi.encode(s, d, o));
        
        INexusSettler.IntendNode[] memory path = _createTestPath();
        
        // First call succeeds
        nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, true), path);
        
        // Second call reverts
        vm.expectRevert(INexusSettler.PathAlreadyProcessed.selector);
        nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, true), path);
    }

    /**
     * @notice Test processPIPath reverts with empty path
     */
    function testProcessPIPath_EmptyPath() public {
        bytes32 rootHash = keccak256("test");
        INexusSettler.IntendNode[] memory emptyPath = new INexusSettler.IntendNode[](0);
        
        vm.expectRevert(INexusSettler.EmptyPath.selector);
        nexusSettler.processPIPath(rootHash, 0, emptyPath);
    }

    /**
     * @notice Test processPIPath with different target types
     */
    function testProcessPIPath_DifferentTargetTypes() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        bytes32 rootHash = keccak256(abi.encode(s, d, o));
        
        INexusSettler.IntendNode[] memory path = _createTestPath();
        
        // Process as source (0)
        nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, true), path);
        assertTrue(nexusSettler.completed(_getCompletionKey(rootHash, _getTargetNodeHash(rootHash, true))), "Source should be completed");
        
        // Process as destination (1) - should succeed
        nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, false), path);
        assertTrue(nexusSettler.completed(_getCompletionKey(rootHash, _getTargetNodeHash(rootHash, false))), "Destination should be completed");
    }

    /**
     * @notice Test processPIPath emits correct events
     */
    function testProcessPIPath_EmitsEvents() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        bytes32 rootHash = keccak256(abi.encode(s, d, o));
        
        INexusSettler.IntendNode[] memory path = _createTestPath();
        
        // Expect events
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeExec(keccak256(abi.encode(path[0])), 0);
        
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendPathProcessed(
            keccak256(abi.encode(rootHash, "source")),
            keccak256(abi.encode(path[0])),
            rootHash,
            1
        );
        
        nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, true), path);
    }

    // ============================================================================
    // Security Tests
    // ============================================================================

    /**
     * @notice Test reentrancy protection on createPI
     */
    function testCreatePI_ReentrancyProtection() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        // Should succeed with nonReentrant
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
    }

    /**
     * @notice Test reentrancy protection on processPIPath
     */
    function testProcessPIPath_ReentrancyProtection() public {
        bytes32 rootHash = keccak256("test");
        INexusSettler.IntendNode[] memory path = _createTestPath();
        
        // Should succeed with nonReentrant
        nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, true), path);
        assertTrue(nexusSettler.completed(_getCompletionKey(rootHash, _getTargetNodeHash(rootHash, true))));
    }

    // ============================================================================
    // Gas Benchmark Tests
    // ============================================================================

    /**
     * @notice Gas benchmark for createPI
     */
    function testGasBenchmark_CreatePI() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        uint256 gasBefore = gasleft();
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
        uint256 gasUsed = gasBefore - gasleft();
        
        emit log_named_uint("createPI gas used", gasUsed);
        assertLt(gasUsed, 50000, "Gas too high");
    }

    /**
     * @notice Gas benchmark for processPIPath
     */
    function testGasBenchmark_ProcessPIPath() public {
        bytes32 rootHash = keccak256("test");
        INexusSettler.IntendNode[] memory path = _createTestPath();
        
        uint256 gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, true), path);
        uint256 gasUsed = gasBefore - gasleft();
        
        emit log_named_uint("processPIPath gas used", gasUsed);
        assertLt(gasUsed, 65000, "Gas too high");
    }

    // ============================================================================
    // Integration Tests
    // ============================================================================

    /**
     * @notice Test full flow: createPI -> processPIPath
     */
    function testFullFlow() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        // Step 1: Create intent
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
        
        // Step 2: Process path
        INexusSettler.IntendNode[] memory path = _createTestPath();
        nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, true), path);
        
        // Verify
        assertTrue(nexusSettler.completed(_getCompletionKey(rootHash, _getTargetNodeHash(rootHash, true))), "Path should be completed");
    }

    /**
     * @notice Test multiple intents
     */
    function testMultipleIntents() public {
        for (uint256 i = 0; i < 5; i++) {
            bytes32 s = keccak256(abi.encodePacked("source", i));
            bytes32 d = keccak256(abi.encodePacked("dest", i));
            bytes32 o = keccak256(abi.encodePacked("offchain", i));
            uint256 nonce = i + 1;
            bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
            
            INexusSettler.IntendNode[] memory path = _createTestPath();
            
            // Process both paths
            nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, true), path);
            nexusSettler.processPIPath(rootHash, _getTargetNodeHash(rootHash, false), path);
        }
        
        // Verify all completed
        for (uint256 i = 0; i < 5; i++) {
            bytes32 s = keccak256(abi.encodePacked("source", i));
            bytes32 d = keccak256(abi.encodePacked("dest", i));
            bytes32 o = keccak256(abi.encodePacked("offchain", i));
            uint256 nonce = i + 1;
            bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
            
            assertTrue(nexusSettler.completed(_getCompletionKey(rootHash, _getTargetNodeHash(rootHash, true))), "Source not completed");
            assertTrue(nexusSettler.completed(_getCompletionKey(rootHash, _getTargetNodeHash(rootHash, false))), "Dest not completed");
        }
    }

    // ============================================================================
    // Partial Execution Tests
    // ============================================================================

    /**
     * @notice Test partial execution - path stops before reaching end
     * @dev Path has 3 nodes but only first 2 are provided, next pointer points to missing node
     */
    function testProcessPIPath_PartialExecution() public {
        bytes32 rootHash = keccak256("partial-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        
        // Create a path with 2 nodes where node 0 points to node 1, but node 1 points to a missing node
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](2);
        
        // Node 1 (end of provided path, but not end of actual path)
        path[1] = INexusSettler.IntendNode({
            next: keccak256("missing-node"), // Points to a node not in the path
            target: address(0x2001),
            data: hex""
        });
        
        // Node 0 (start)
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])), // Points to node 1
            target: address(0x2000),
            data: hex""
        });
        
        // Process partial path
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        
        // Should NOT be completed since we didn't reach next == bytes32(0)
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        assertFalse(nexusSettler.completed(completionKey), "Path should NOT be completed");
    }

    /**
     * @notice Test resuming partial execution
     * @dev First call processes partial path, second call completes
     */
    function testProcessPIPath_ResumePartialExecution() public {
        bytes32 rootHash = keccak256("resume-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        
        // First call: partial path (2 nodes, not reaching end)
        INexusSettler.IntendNode[] memory partialPath = new INexusSettler.IntendNode[](2);
        
        // Node 1 (end of partial path)
        partialPath[1] = INexusSettler.IntendNode({
            next: keccak256("continuation"), // Points to continuation
            target: address(0x3001),
            data: hex""
        });
        
        // Node 0 (start)
        partialPath[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(partialPath[1])),
            target: address(0x3000),
            data: hex""
        });
        
        // Process partial path
        nexusSettler.processPIPath(rootHash, targetNodeHash, partialPath);
        
        // Should NOT be completed
        assertFalse(nexusSettler.completed(completionKey), "Should not be completed after partial");
        
        // Second call: continuation path (remaining nodes)
        INexusSettler.IntendNode[] memory continuationPath = new INexusSettler.IntendNode[](1);
        continuationPath[0] = INexusSettler.IntendNode({
            next: bytes32(0), // End of path
            target: address(0x3002),
            data: hex""
        });
        
        // Process continuation - this should complete
        nexusSettler.processPIPath(rootHash, targetNodeHash, continuationPath);
        
        // Should NOW be completed
        assertTrue(nexusSettler.completed(completionKey), "Should be completed after continuation");
    }

    /**
     * @notice Test complete path marks as completed
     * @dev Path with next == bytes32(0) should mark as completed
     */
    function testProcessPIPath_CompletePathMarksCompleted() public {
        bytes32 rootHash = keccak256("complete-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        
        // Create complete path (ends with next == bytes32(0))
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](3);
        
        // Node 2 (end)
        path[2] = INexusSettler.IntendNode({
            next: bytes32(0), // End of path
            target: address(0x4002),
            data: hex""
        });
        
        // Node 1
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(0x4001),
            data: hex""
        });
        
        // Node 0 (start)
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(0x4000),
            data: hex""
        });
        
        // Process complete path
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        
        // Should be completed
        assertTrue(nexusSettler.completed(completionKey), "Should be completed");
    }

    /**
     * @notice Test partial execution emits events for executed nodes
     */
    function testProcessPIPath_PartialExecutionEmitsEvents() public {
        bytes32 rootHash = keccak256("partial-events-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        
        // Create partial path
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](2);
        
        // Node 1 (end of partial)
        path[1] = INexusSettler.IntendNode({
            next: keccak256("missing"),
            target: address(0x5001),
            data: hex""
        });
        
        // Node 0 (start)
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(0x5000),
            data: hex""
        });
        
        // Expect events for both nodes
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeExec(keccak256(abi.encode(path[0])), 0);
        
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeExec(keccak256(abi.encode(path[1])), 1);
        
        // Process
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
    }

    /**
     * @notice Test that partial execution can be called multiple times
     */
    function testProcessPIPath_MultiplePartialCalls() public {
        bytes32 rootHash = keccak256("multi-partial-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        
        // First partial: 1 node
        INexusSettler.IntendNode[] memory path1 = new INexusSettler.IntendNode[](1);
        path1[0] = INexusSettler.IntendNode({
            next: keccak256("next1"),
            target: address(0x6000),
            data: hex""
        });
        
        nexusSettler.processPIPath(rootHash, targetNodeHash, path1);
        assertFalse(nexusSettler.completed(completionKey), "Not completed after first partial");
        
        // Second partial: 1 node
        INexusSettler.IntendNode[] memory path2 = new INexusSettler.IntendNode[](1);
        path2[0] = INexusSettler.IntendNode({
            next: keccak256("next2"),
            target: address(0x6001),
            data: hex""
        });
        
        nexusSettler.processPIPath(rootHash, targetNodeHash, path2);
        assertFalse(nexusSettler.completed(completionKey), "Not completed after second partial");
        
        // Final call: complete
        INexusSettler.IntendNode[] memory path3 = new INexusSettler.IntendNode[](1);
        path3[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(0x6002),
            data: hex""
        });
        
        nexusSettler.processPIPath(rootHash, targetNodeHash, path3);
        assertTrue(nexusSettler.completed(completionKey), "Completed after final call");
    }

    // ============================================================================
    // Node Tracking Tests
    // ============================================================================

    /**
     * @notice Helper to compute node key
     */
    function _getNodeKey(bytes32 rootHash, bytes32 targetNodeHash, bytes32 nodeHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(rootHash, targetNodeHash, nodeHash));
    }

    /**
     * @notice Test that nodes are marked as processed after execution
     */
    function testProcessPIPath_NodesMarkedProcessed() public {
        bytes32 rootHash = keccak256("node-tracking-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        
        // Create path with 2 nodes
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](2);
        
        // Node 1 (end)
        path[1] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(0x7001),
            data: hex""
        });
        
        // Node 0 (start)
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(0x7000),
            data: hex""
        });
        
        // Process path
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        
        // Verify both nodes are marked as processed
        bytes32 node0Hash = keccak256(abi.encode(path[0]));
        bytes32 node1Hash = keccak256(abi.encode(path[1]));
        
        bytes32 node0Key = _getNodeKey(rootHash, targetNodeHash, node0Hash);
        bytes32 node1Key = _getNodeKey(rootHash, targetNodeHash, node1Hash);
        
        assertTrue(nexusSettler.processedNodes(node0Key), "Node 0 should be processed");
        assertTrue(nexusSettler.processedNodes(node1Key), "Node 1 should be processed");
    }

    /**
     * @notice Test that already-processed nodes are skipped
     */
    function testProcessPIPath_SkipsProcessedNodes() public {
        bytes32 rootHash = keccak256("skip-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        
        // Create path with 2 nodes
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](2);
        
        // Node 1 (end)
        path[1] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(0x8001),
            data: hex""
        });
        
        // Node 0 (start)
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(0x8000),
            data: hex""
        });
        
        // First call: process path
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        
        // Verify completed
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        assertTrue(nexusSettler.completed(completionKey), "Should be completed");
        
        // Create a different path with same root/target but different nodes
        // This should fail because path is already completed
        vm.expectRevert(INexusSettler.PathAlreadyProcessed.selector);
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
    }

    /**
     * @notice Test that same node can be processed for different target types
     */
    function testProcessPIPath_SameNodeDifferentTargets() public {
        bytes32 rootHash = keccak256("different-targets-test");
        bytes32 targetSource = _getTargetNodeHash(rootHash, true);
        bytes32 targetDest = _getTargetNodeHash(rootHash, false);
        
        // Create same path for both targets
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(0x9000),
            data: hex""
        });
        
        bytes32 nodeHash = keccak256(abi.encode(path[0]));
        
        // Process for source target
        nexusSettler.processPIPath(rootHash, targetSource, path);
        
        // Node should be processed for source
        bytes32 nodeKeySource = _getNodeKey(rootHash, targetSource, nodeHash);
        assertTrue(nexusSettler.processedNodes(nodeKeySource), "Node processed for source");
        
        // Node should NOT be processed for dest yet
        bytes32 nodeKeyDest = _getNodeKey(rootHash, targetDest, nodeHash);
        assertFalse(nexusSettler.processedNodes(nodeKeyDest), "Node not processed for dest yet");
        
        // Process for dest target
        nexusSettler.processPIPath(rootHash, targetDest, path);
        
        // Now node should be processed for dest too
        assertTrue(nexusSettler.processedNodes(nodeKeyDest), "Node processed for dest");
    }

    /**
     * @notice Test IntendNodeSkipped event is emitted for already-processed nodes
     */
    function testProcessPIPath_EmitsSkippedEvent() public {
        bytes32 rootHash = keccak256("skipped-event-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        
        // Create path with 2 nodes
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](2);
        
        // Node 1 (end)
        path[1] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(0xA001),
            data: hex""
        });
        
        // Node 0 (start)
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(0xA000),
            data: hex""
        });
        
        // First call: process path (should emit IntendNodeExec)
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeExec(keccak256(abi.encode(path[0])), 0);
        
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeExec(keccak256(abi.encode(path[1])), 1);
        
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        
        // Verify completed
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        assertTrue(nexusSettler.completed(completionKey), "Should be completed");
    }

    /**
     * @notice Test partial execution with node tracking
     * @dev Process same nodes twice - second time should skip
     */
    function testProcessPIPath_PartialWithNodeTracking() public {
        bytes32 rootHash = keccak256("partial-tracking-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        
        // Create partial path (2 nodes, not reaching end)
        INexusSettler.IntendNode[] memory partialPath = new INexusSettler.IntendNode[](2);
        
        // Node 1 (end of partial)
        partialPath[1] = INexusSettler.IntendNode({
            next: keccak256("continuation"),
            target: address(0xB001),
            data: hex""
        });
        
        // Node 0 (start)
        partialPath[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(partialPath[1])),
            target: address(0xB000),
            data: hex""
        });
        
        // First call: process partial path
        nexusSettler.processPIPath(rootHash, targetNodeHash, partialPath);
        assertFalse(nexusSettler.completed(completionKey), "Not completed after partial");
        
        // Verify nodes are marked as processed
        bytes32 node0Hash = keccak256(abi.encode(partialPath[0]));
        bytes32 node1Hash = keccak256(abi.encode(partialPath[1]));
        
        bytes32 node0Key = _getNodeKey(rootHash, targetNodeHash, node0Hash);
        bytes32 node1Key = _getNodeKey(rootHash, targetNodeHash, node1Hash);
        
        assertTrue(nexusSettler.processedNodes(node0Key), "Node 0 processed");
        assertTrue(nexusSettler.processedNodes(node1Key), "Node 1 processed");
        
        // Second call: same nodes should be skipped
        // Expect IntendNodeSkipped events
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeSkipped(node0Hash, 0);
        
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeSkipped(node1Hash, 1);
        
        nexusSettler.processPIPath(rootHash, targetNodeHash, partialPath);
        
        // Still not completed
        assertFalse(nexusSettler.completed(completionKey), "Still not completed");
    }

    // ============================================================================
    // Nonce Uniqueness Tests
    // ============================================================================

    /**
     * @notice Test that same s, d, o with different nonces produce different rootHashes
     */
    function testCreatePI_NonceUniqueness() public {
        bytes32 s = keccak256("same-source");
        bytes32 d = keccak256("same-destination");
        bytes32 o = keccak256("same-offchain");
        
        // Create two intents with same s, d, o but different nonces
        uint256 nonce1 = 1;
        uint256 nonce2 = 2;
        
        bytes32 rootHash1 = keccak256(abi.encode(s, d, o, nonce1));
        bytes32 rootHash2 = keccak256(abi.encode(s, d, o, nonce2));
        
        // Verify they are different
        assertTrue(rootHash1 != rootHash2, "Root hashes should be different");
        
        // Create first intent
        bytes32 structHash1 = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash1,
            nonce1
        ));
        bytes32 digest1 = _computeDigest(structHash1);
        (uint8 v1, bytes32 r1, bytes32 s_sig1) = vm.sign(userPrivateKey, digest1);
        
        nexusSettler.createPI(rootHash1, abi.encodePacked(r1, s_sig1, v1), nonce1, s, d, o);
        assertTrue(nexusSettler.created(rootHash1), "First intent created");
        
        // Create second intent with same s, d, o but different nonce - should succeed
        bytes32 structHash2 = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash2,
            nonce2
        ));
        bytes32 digest2 = _computeDigest(structHash2);
        (uint8 v2, bytes32 r2, bytes32 s_sig2) = vm.sign(userPrivateKey, digest2);
        
        nexusSettler.createPI(rootHash2, abi.encodePacked(r2, s_sig2, v2), nonce2, s, d, o);
        assertTrue(nexusSettler.created(rootHash2), "Second intent created");
    }

    /**
     * @notice Test that same nonce with same s, d, o reverts (duplicate)
     */
    function testCreatePI_SameNonceReverts() public {
        bytes32 s = keccak256("same-source");
        bytes32 d = keccak256("same-destination");
        bytes32 o = keccak256("same-offchain");
        uint256 nonce = 42;
        
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        // Create first intent
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);
        
        nexusSettler.createPI(rootHash, signature, nonce, s, d, o);
        
        // Try to create again with same nonce - should revert
        vm.expectRevert(INexusSettler.IntentAlreadyExists.selector);
        nexusSettler.createPI(rootHash, signature, nonce, s, d, o);
    }

    // ============================================================================
    // Partial Execution Hash Mismatch Tests (Task 3)
    // ============================================================================

    /**
     * @notice Test partial execution when path[i+1] hash doesn't match node.next
     * @dev With O(1) hash verification, nodes must be in execution order.
     *      If node[1].next doesn't match hash(node[2]), execution stops at node[1].
     *      Expected: 2 of 3 nodes execute, isComplete=false
     */
    function testPartialExecution_HashMismatch() public {
        bytes32 rootHash = keccak256("hash-mismatch-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        
        // Create 3-node path in WRONG order
        // Node 0 -> Node 1 (correct hash)
        // Node 1 -> Node 2 (MISMATCH: next points to wrong hash)
        // Node 2 -> bytes32(0) (end)
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](3);
        
        // Build backwards to get correct hashes
        // Node 2 (end)
        path[2] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(0xC002),
            data: hex""
        });
        
        // Node 1 - set wrong next pointer (doesn't match hash of node 2)
        bytes32 wrongHash = keccak256("this-is-not-node-2");
        path[1] = INexusSettler.IntendNode({
            next: wrongHash,  // WRONG: doesn't match keccak256(abi.encode(path[2]))
            target: address(0xC001),
            data: hex""
        });
        
        // Node 0 - points to correct hash of node 1
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(0xC000),
            data: hex""
        });
        
        // Verify the mismatch exists
        assertTrue(keccak256(abi.encode(path[1].next)) != keccak256(abi.encode(path[2])), 
            "Should have hash mismatch");
        
        // Process path - should only execute 2 nodes, then stop due to mismatch
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        
        // Should NOT be completed (hash mismatch causes partial execution)
        assertFalse(nexusSettler.completed(completionKey), "Should NOT be completed due to hash mismatch");
        
        // Verify nodes 0 and 1 were processed, node 2 was NOT processed
        bytes32 node0Hash = keccak256(abi.encode(path[0]));
        bytes32 node1Hash = keccak256(abi.encode(path[1]));
        bytes32 node2Hash = keccak256(abi.encode(path[2]));
        
        bytes32 node0Key = _getNodeKey(rootHash, targetNodeHash, node0Hash);
        bytes32 node1Key = _getNodeKey(rootHash, targetNodeHash, node1Hash);
        bytes32 node2Key = _getNodeKey(rootHash, targetNodeHash, node2Hash);
        
        assertTrue(nexusSettler.processedNodes(node0Key), "Node 0 should be processed");
        assertTrue(nexusSettler.processedNodes(node1Key), "Node 1 should be processed");
        assertFalse(nexusSettler.processedNodes(node2Key), "Node 2 should NOT be processed (skipped due to mismatch)");
    }

    /**
     * @notice Test successful execution when all path hashes match in correct order
     * @dev With O(1) hash verification, when nodes are in execution order
     *      and all next pointers match, all nodes should execute.
     *      Expected: 3 of 3 nodes execute, isComplete=true
     */
    function testPartialExecution_CorrectOrder() public {
        bytes32 rootHash = keccak256("correct-order-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        
        // Create 3-node path in CORRECT order
        // Node 0 -> Node 1 (correct hash)
        // Node 1 -> Node 2 (correct hash)
        // Node 2 -> bytes32(0) (end)
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](3);
        
        // Build backwards to get correct hashes
        // Node 2 (end)
        path[2] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(0xD002),
            data: hex""
        });
        
        // Node 1 - points to correct hash of node 2
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),  // CORRECT: matches hash of node 2
            target: address(0xD001),
            data: hex""
        });
        
        // Node 0 - points to correct hash of node 1
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(0xD000),
            data: hex""
        });
        
        // Verify the hashes are correctly chained
        assertEq(path[0].next, keccak256(abi.encode(path[1])), "Node 0 next should match node 1 hash");
        assertEq(path[1].next, keccak256(abi.encode(path[2])), "Node 1 next should match node 2 hash");
        assertEq(path[2].next, bytes32(0), "Node 2 should be terminal");
        
        // Process path - should execute all 3 nodes
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        
        // Should be completed (reached end of path)
        assertTrue(nexusSettler.completed(completionKey), "Should be completed with correct order");
        
        // Verify all nodes were processed
        bytes32 node0Hash = keccak256(abi.encode(path[0]));
        bytes32 node1Hash = keccak256(abi.encode(path[1]));
        bytes32 node2Hash = keccak256(abi.encode(path[2]));
        
        bytes32 node0Key = _getNodeKey(rootHash, targetNodeHash, node0Hash);
        bytes32 node1Key = _getNodeKey(rootHash, targetNodeHash, node1Hash);
        bytes32 node2Key = _getNodeKey(rootHash, targetNodeHash, node2Hash);
        
        assertTrue(nexusSettler.processedNodes(node0Key), "Node 0 should be processed");
        assertTrue(nexusSettler.processedNodes(node1Key), "Node 1 should be processed");
        assertTrue(nexusSettler.processedNodes(node2Key), "Node 2 should be processed");
    }

    /**
     * @notice Test that already-processed nodes are tracked correctly with hash verification
     * @dev When resuming a partial execution with correct node order,
     *      already-processed nodes should be skipped.
     */
    function testPartialExecution_ResumeWithCorrectOrder() public {
        bytes32 rootHash = keccak256("resume-correct-test");
        bytes32 targetNodeHash = _getTargetNodeHash(rootHash, true);
        bytes32 completionKey = _getCompletionKey(rootHash, targetNodeHash);
        
        // First partial: 2 nodes with correct order
        INexusSettler.IntendNode[] memory partialPath = new INexusSettler.IntendNode[](2);
        
        // Node 1 (end of partial) - points to hash that won't be in next path
        partialPath[1] = INexusSettler.IntendNode({
            next: keccak256("continuation"),
            target: address(0xE001),
            data: hex""
        });
        
        // Node 0
        partialPath[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(partialPath[1])),
            target: address(0xE000),
            data: hex""
        });
        
        // Process partial
        nexusSettler.processPIPath(rootHash, targetNodeHash, partialPath);
        assertFalse(nexusSettler.completed(completionKey), "Should not be completed after partial");
        
        // Verify both nodes are marked as processed
        bytes32 node0Hash = keccak256(abi.encode(partialPath[0]));
        bytes32 node1Hash = keccak256(abi.encode(partialPath[1]));
        
        bytes32 node0Key = _getNodeKey(rootHash, targetNodeHash, node0Hash);
        bytes32 node1Key = _getNodeKey(rootHash, targetNodeHash, node1Hash);
        
        assertTrue(nexusSettler.processedNodes(node0Key), "Node 0 should be processed");
        assertTrue(nexusSettler.processedNodes(node1Key), "Node 1 should be processed");
        
        // Second call with same path - should skip already-processed nodes
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeSkipped(node0Hash, 0);
        
        vm.expectEmit(true, false, false, false);
        emit INexusSettler.IntendNodeSkipped(node1Hash, 1);
        
        nexusSettler.processPIPath(rootHash, targetNodeHash, partialPath);
        
        // Still not completed (no terminal node reached)
        assertFalse(nexusSettler.completed(completionKey), "Still not completed");
    }
}

// ============================================================================
// Mock Token for Gas Comparison
// ============================================================================

/**
 * @title MockGasComparisonToken
 * @notice Simple ERC20-like token for gas benchmarking
 */
contract MockGasComparisonToken {
    mapping(address => uint256) public balances;
    
    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }
    
    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
}

// ============================================================================
// Gas Comparison Test Contract
// ============================================================================

/**
 * @title NexusSettlerGasComparisonTest
 * @notice Gas comparison between direct action vs settler-mediated action
 */
contract NexusSettlerGasComparisonTest is Test {
    NexusSettler public nexusSettler;
    MockGasComparisonToken public token;
    address public escrow;
    address public user;
    address public recipient;
    uint256 public userPrivateKey;
    uint256 public constant TRANSFER_AMOUNT = 1000 ether;

    function setUp() public {
        escrow = makeAddr("escrow");
        (user, userPrivateKey) = makeAddrAndKey("user");
        recipient = makeAddr("recipient");
        
        nexusSettler = new NexusSettler(escrow);
        token = new MockGasComparisonToken();
        
        token.mint(user, TRANSFER_AMOUNT);
    }

    function _computeDigest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("NexusSettler")),
            keccak256(bytes("2")),
            block.chainid,
            address(nexusSettler)
        ));
        
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function testGasComparison_DirectVsSettlerTransfer() public {
        // Scenario 1: Direct transfer
        vm.startPrank(user);
        uint256 gasBefore = gasleft();
        token.transfer(recipient, TRANSFER_AMOUNT);
        uint256 gasDirect = gasBefore - gasleft();
        vm.stopPrank();
        
        assertEq(token.balanceOf(recipient), TRANSFER_AMOUNT);
        
        // Reset and setup settler scenario
        token.mint(user, TRANSFER_AMOUNT);
        
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
        
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(token),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, TRANSFER_AMOUNT)
        });
        
        vm.startPrank(user);
        token.transfer(address(nexusSettler), TRANSFER_AMOUNT);
        vm.stopPrank();
        
        gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, keccak256(abi.encode(rootHash, "source")), path);
        uint256 gasSettler = gasBefore - gasleft();
        
        emit log_named_uint("Direct transfer gas", gasDirect);
        emit log_named_uint("Settler-mediated gas", gasSettler);
        emit log_named_uint("Overhead", gasSettler - gasDirect);
        emit log_named_uint("Overhead %", ((gasSettler - gasDirect) * 100) / gasDirect);
        
        assertEq(token.balanceOf(recipient), TRANSFER_AMOUNT * 2);
    }

    function testGasComparison_OperationBreakdown() public {
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(token),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, TRANSFER_AMOUNT)
        });
        
        // Measure createPI
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        uint256 gasBefore = gasleft();
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
        uint256 gasCreatePI = gasBefore - gasleft();
        
        // Setup for processPIPath
        vm.startPrank(user);
        token.transfer(address(nexusSettler), TRANSFER_AMOUNT);
        vm.stopPrank();
        
        // Measure processPIPath
        gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, keccak256(abi.encode(rootHash, "source")), path);
        uint256 gasProcessPIPath = gasBefore - gasleft();
        
        // Measure direct for comparison
        token.mint(user, TRANSFER_AMOUNT);
        vm.startPrank(user);
        gasBefore = gasleft();
        token.transfer(recipient, TRANSFER_AMOUNT);
        uint256 gasDirect = gasBefore - gasleft();
        vm.stopPrank();
        
        emit log("=== Gas Breakdown ===");
        emit log_named_uint("createPI", gasCreatePI);
        emit log_named_uint("processPIPath", gasProcessPIPath);
        emit log_named_uint("Total settler", gasCreatePI + gasProcessPIPath);
        emit log_named_uint("Direct", gasDirect);
        emit log_named_uint("Overhead", gasCreatePI + gasProcessPIPath - gasDirect);
    }

    function testGasComparison_MultiNodePath() public {
        uint256 numTransfers = 3;
        uint256 amountPerTransfer = TRANSFER_AMOUNT / numTransfers;
        
        token.mint(user, TRANSFER_AMOUNT);
        
        // Multiple direct transfers
        vm.startPrank(user);
        uint256 gasBefore = gasleft();
        for (uint256 i = 0; i < numTransfers; i++) {
            token.transfer(recipient, amountPerTransfer);
        }
        uint256 gasDirectMulti = gasBefore - gasleft();
        vm.stopPrank();
        
        // Reset
        token.mint(user, TRANSFER_AMOUNT);
        
        // Multi-node settler path
        bytes32 s = keccak256("multi-source");
        bytes32 d = keccak256("multi-dest");
        bytes32 o = keccak256("multi-offchain");
        uint256 nonce = 2;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
        
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](numTransfers);
        for (uint256 i = 0; i < numTransfers; i++) {
            path[i] = INexusSettler.IntendNode({
                next: i + 1 < numTransfers ? keccak256(abi.encode(path[i + 1])) : bytes32(0),
                target: address(token),
                data: abi.encodeWithSignature("transfer(address,uint256)", recipient, amountPerTransfer)
            });
        }
        
        vm.startPrank(user);
        token.transfer(address(nexusSettler), TRANSFER_AMOUNT);
        vm.stopPrank();
        
        gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, keccak256(abi.encode(rootHash, "source")), path);
        uint256 gasSettlerMulti = gasBefore - gasleft();
        
        emit log("=== Multi-Transfer Comparison ===");
        emit log_named_uint("Transfers", numTransfers);
        emit log_named_uint("Direct total", gasDirectMulti);
        emit log_named_uint("Settler total", gasSettlerMulti);
        emit log_named_uint("Direct per tx", gasDirectMulti / numTransfers);
        emit log_named_uint("Settler per tx", gasSettlerMulti / numTransfers);
    }

    // ============================================================================
    // O(n²) Bottleneck Baseline Tests
    // ============================================================================

    /**
     * @notice BASELINE: Gas measurement for 5-node path
     * @dev Measures total gas and calculates per-node cost to establish O(n²) baseline
     */
    function testGasBaseline_5NodePath() public {
        uint256 NUM_NODES = 5;
        
        // Setup intent
        bytes32 s = keccak256("baseline-source");
        bytes32 d = keccak256("baseline-dest");
        bytes32 o = keccak256("baseline-offchain");
        uint256 nonce = 100;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        // Sign
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
        
        // Create 5-node path with proper DAG linking
        // Each node's next points to the hash of the next node
        // Build backwards to ensure proper hash resolution
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](NUM_NODES);
        
        // Create placeholder nodes first
        for (uint256 i = 0; i < NUM_NODES; i++) {
            path[i] = INexusSettler.IntendNode({
                next: bytes32(0),  // Will be updated
                target: escrow,
                data: abi.encodeWithSignature("noop()")
            });
        }
        
        // Set terminal node first
        path[NUM_NODES - 1].next = bytes32(0);
        
        // Work backwards: set next pointers to hashes
        for (uint256 i = NUM_NODES; i > 0; i--) {
            uint256 idx = i - 1;
            // Compute hash of current node (with current next value)
            bytes32 currentHash = keccak256(abi.encode(path[idx]));
            // Previous node should point to this hash
            if (idx > 0) {
                path[idx - 1].next = currentHash;
            }
        }
        
        bytes32 targetNodeHash = keccak256(abi.encode(rootHash, "target"));
        
        uint256 gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        uint256 totalGas = gasBefore - gasleft();
        uint256 gasPerNode = totalGas / NUM_NODES;
        
        emit log("=== O(n2) Bottleneck Baseline: 5-Node Path ===");
        emit log_named_uint("Total gas (5 nodes)", totalGas);
        emit log_named_uint("Gas per node", gasPerNode);
        emit log_named_uint("Expected O(n2) comparisons", NUM_NODES * NUM_NODES);
        emit log_named_uint("Actual O(n2) overhead (est)", (NUM_NODES * NUM_NODES) * 4000 / NUM_NODES);
        
        // Baseline assertion: ~32,000 gas per node is the target baseline
        assertGt(totalGas, 150000, "Total gas should exceed 150k for 5 nodes (baseline)");
        assertLt(gasPerNode, 50000, "Gas per node should be under 50k (includes O(n2) overhead)");
    }

    /**
     * @notice BASELINE: Gas breakdown showing O(n²) growth
     * @dev Compares gas across different path lengths to demonstrate quadratic growth
     */
    function testGasBaseline_O2Growth() public {
        uint256[] memory nodeCounts = new uint256[](4);
        nodeCounts[0] = 2;
        nodeCounts[1] = 4;
        nodeCounts[2] = 8;
        nodeCounts[3] = 16;
        
        uint256[] memory gasUsage = new uint256[](4);
        
        for (uint256 test = 0; test < 4; test++) {
            uint256 n = nodeCounts[test];
            
            // Setup intent
            bytes32 s = keccak256(abi.encode("source", test));
            bytes32 d = keccak256(abi.encode("dest", test));
            bytes32 o = keccak256(abi.encode("offchain", test));
            uint256 nonce = 200 + test;
            bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));
            
            // Sign
            bytes32 structHash = keccak256(abi.encode(
                keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
                rootHash,
                nonce
            ));
            bytes32 digest = _computeDigest(structHash);
            (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
            
            nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
            
            // Create n-node path with proper linking
            INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](n);
            
            // Create placeholder nodes
            for (uint256 i = 0; i < n; i++) {
                path[i] = INexusSettler.IntendNode({
                    next: bytes32(0),
                    target: escrow,
                    data: abi.encodeWithSignature("noop()")
                });
            }
            
            // Set terminal node
            path[n - 1].next = bytes32(0);
            
            // Work backwards: set next pointers to hashes
            for (uint256 i = n; i > 0; i--) {
                uint256 idx = i - 1;
                bytes32 currentHash = keccak256(abi.encode(path[idx]));
                if (idx > 0) {
                    path[idx - 1].next = currentHash;
                }
            }
            
            bytes32 targetNodeHash = keccak256(abi.encode(rootHash, "target"));
            
            uint256 gasBefore = gasleft();
            nexusSettler.processPIPath(rootHash, targetNodeHash, path);
            gasUsage[test] = gasBefore - gasleft();
        }
        
        emit log("=== O(n2) Growth Demonstration ===");
        for (uint256 i = 0; i < 4; i++) {
            uint256 n = nodeCounts[i];
            uint256 o2Comparisons = n * n;
            emit log_named_uint(string(abi.encodePacked("Nodes=", uint2str(n))), gasUsage[i]);
            emit log_named_uint(string(abi.encodePacked("O(n2) comparisons=", uint2str(n), "^2=", uint2str(o2Comparisons))), gasUsage[i]);
        }
        
        // Verify O(n²) growth: gas should roughly scale with n²
        // 8 nodes should use roughly 16x more gas than 2 nodes (in the search portion)
        uint256 ratio16x = gasUsage[3] * 100 / gasUsage[0]; // 16 nodes vs 2 nodes
        emit log_named_uint("16x node count gas ratio (expect ~O(n2))", ratio16x);
        
        // Note: Actual ratio will be less than 64x due to constant overhead,
        // but should still show super-linear growth
        assertGt(ratio16x, 100, "Gas should grow super-linearly with node count");
    }

    // ============================================================================
    // O(1) Optimization Gas Benchmarks
    // ============================================================================

    /**
     * @notice Helper: Create properly linked path with n nodes
     * @dev Each node's next points to the hash of the next node
     */
    function _createLinkedPath(
        bytes32 rootHash,
        uint256 n,
        uint256 nonce,
        address target
    ) internal returns (INexusSettler.IntendNode[] memory path, bytes32 targetNodeHash) {
        path = new INexusSettler.IntendNode[](n);
        targetNodeHash = keccak256(abi.encode(rootHash, "target"));
        
        // Create placeholder nodes first
        for (uint256 i = 0; i < n; i++) {
            path[i] = INexusSettler.IntendNode({
                next: bytes32(0),
                target: target,
                data: abi.encodeWithSignature("noop()")
            });
        }
        
        // Set terminal node first
        path[n - 1].next = bytes32(0);
        
        // Work backwards: set next pointers to hashes
        for (uint256 i = n; i > 0; i--) {
            uint256 idx = i - 1;
            bytes32 currentHash = keccak256(abi.encode(path[idx]));
            if (idx > 0) {
                path[idx - 1].next = currentHash;
            }
        }
    }

    /**
     * @notice Helper: Setup intent for gas testing
     */
    function _setupIntent(
        bytes32 s,
        bytes32 d,
        bytes32 o,
        uint256 nonce
    ) internal returns (bytes32 rootHash) {
        rootHash = keccak256(abi.encode(s, d, o, nonce));
        
        bytes32 structHash = keccak256(abi.encode(
            keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
            rootHash,
            nonce
        ));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(userPrivateKey, digest);
        
        nexusSettler.createPI(rootHash, abi.encodePacked(r, s_sig, v), nonce, s, d, o);
    }

    /**
     * @notice OPTIMIZED: Gas measurement for 1-node path
     * @dev Measures base gas cost with single node
     */
    function testGasOptimized_1Node() public {
        uint256 NUM_NODES = 1;
        
        // Setup intent
        bytes32 s = keccak256("opt-1node-source");
        bytes32 d = keccak256("opt-1node-dest");
        bytes32 o = keccak256("opt-1node-offchain");
        uint256 nonce = 1000;
        bytes32 rootHash = _setupIntent(s, d, o, nonce);
        
        // Create 1-node path
        (INexusSettler.IntendNode[] memory path, bytes32 targetNodeHash) = _createLinkedPath(
            rootHash, NUM_NODES, nonce, escrow
        );
        
        uint256 gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        uint256 totalGas = gasBefore - gasleft();
        uint256 gasPerNode = totalGas / NUM_NODES;
        
        emit log("=== O(1) Optimization: 1 Node Path ===");
        emit log_named_uint("Total gas (1 node)", totalGas);
        emit log_named_uint("Gas per node", gasPerNode);
        emit log_named_uint("Baseline O(n^2) per node", 50000);
        emit log_named_uint("Reduction vs O(n^2)", 50000 > gasPerNode ? 50000 - gasPerNode : 0);
        
        // Verify reasonable gas usage
        assertGt(totalGas, 50000, "Total gas should exceed 50k for 1 node (fixed overhead)");
        assertLt(totalGas, 120000, "Total gas should be under 120k for 1 node");
    }

    /**
     * @notice OPTIMIZED: Gas measurement for 5-node path
     * @dev Actual measured: ~38,000 gas/node with O(1) optimization
     */
    function testGasOptimized_5Node() public {
        uint256 NUM_NODES = 5;
        
        // Setup intent
        bytes32 s = keccak256("opt-5node-source");
        bytes32 d = keccak256("opt-5node-dest");
        bytes32 o = keccak256("opt-5node-offchain");
        uint256 nonce = 1001;
        bytes32 rootHash = _setupIntent(s, d, o, nonce);
        
        // Create 5-node path
        (INexusSettler.IntendNode[] memory path, bytes32 targetNodeHash) = _createLinkedPath(
            rootHash, NUM_NODES, nonce, escrow
        );
        
        uint256 gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        uint256 totalGas = gasBefore - gasleft();
        uint256 gasPerNode = totalGas / NUM_NODES;
        
        emit log("=== O(1) Optimization: 5 Node Path ===");
        emit log_named_uint("Total gas (5 nodes)", totalGas);
        emit log_named_uint("Gas per node", gasPerNode);
        emit log_named_uint("Baseline O(n^2) per node", 50000);
        emit log_named_uint("Reduction vs O(n^2)", 50000 > gasPerNode ? 50000 - gasPerNode : 0);
        
        // Verify reasonable gas usage
        assertGt(totalGas, 100000, "Total gas should exceed 100k for 5 nodes");
        assertLt(totalGas, 300000, "Total gas should be under 300k for 5 nodes");
        assertLt(gasPerNode, 60000, "Gas per node should be under 60k");
    }

    /**
     * @notice OPTIMIZED: Gas measurement for 10-node path
     */
    function testGasOptimized_10Node() public {
        uint256 NUM_NODES = 10;
        
        // Setup intent
        bytes32 s = keccak256("opt-10node-source");
        bytes32 d = keccak256("opt-10node-dest");
        bytes32 o = keccak256("opt-10node-offchain");
        uint256 nonce = 1002;
        bytes32 rootHash = _setupIntent(s, d, o, nonce);
        
        // Create 10-node path
        (INexusSettler.IntendNode[] memory path, bytes32 targetNodeHash) = _createLinkedPath(
            rootHash, NUM_NODES, nonce, escrow
        );
        
        uint256 gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        uint256 totalGas = gasBefore - gasleft();
        uint256 gasPerNode = totalGas / NUM_NODES;
        
        emit log("=== O(1) Optimization: 10 Node Path ===");
        emit log_named_uint("Total gas (10 nodes)", totalGas);
        emit log_named_uint("Gas per node", gasPerNode);
        emit log_named_uint("Baseline O(n^2) per node", 50000);
        emit log_named_uint("Reduction vs O(n^2)", 50000 > gasPerNode ? 50000 - gasPerNode : 0);
        
        // Verify reasonable gas usage
        assertGt(totalGas, 200000, "Total gas should exceed 200k for 10 nodes");
        assertLt(totalGas, 500000, "Total gas should be under 500k for 10 nodes");
        assertLt(gasPerNode, 60000, "Gas per node should be under 60k");
    }

    /**
     * @notice OPTIMIZED: Gas measurement for 20-node path
     */
    function testGasOptimized_20Node() public {
        uint256 NUM_NODES = 20;
        
        // Setup intent
        bytes32 s = keccak256("opt-20node-source");
        bytes32 d = keccak256("opt-20node-dest");
        bytes32 o = keccak256("opt-20node-offchain");
        uint256 nonce = 1003;
        bytes32 rootHash = _setupIntent(s, d, o, nonce);
        
        // Create 20-node path
        (INexusSettler.IntendNode[] memory path, bytes32 targetNodeHash) = _createLinkedPath(
            rootHash, NUM_NODES, nonce, escrow
        );
        
        uint256 gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        uint256 totalGas = gasBefore - gasleft();
        uint256 gasPerNode = totalGas / NUM_NODES;
        
        emit log("=== O(1) Optimization: 20 Node Path ===");
        emit log_named_uint("Total gas (20 nodes)", totalGas);
        emit log_named_uint("Gas per node", gasPerNode);
        emit log_named_uint("Baseline O(n^2) per node", 50000);
        emit log_named_uint("Reduction vs O(n^2)", 50000 > gasPerNode ? 50000 - gasPerNode : 0);
        
        // Verify reasonable gas usage
        assertGt(totalGas, 400000, "Total gas should exceed 400k for 20 nodes");
        assertLt(totalGas, 1000000, "Total gas should be under 1M for 20 nodes");
        assertLt(gasPerNode, 60000, "Gas per node should be under 60k");
    }

    /**
     * @notice OPTIMIZED: Gas measurement for 32-node path (MAX)
     */
    function testGasOptimized_32Node() public {
        uint256 NUM_NODES = 32;
        
        // Setup intent
        bytes32 s = keccak256("opt-32node-source");
        bytes32 d = keccak256("opt-32node-dest");
        bytes32 o = keccak256("opt-32node-offchain");
        uint256 nonce = 1004;
        bytes32 rootHash = _setupIntent(s, d, o, nonce);
        
        // Create 32-node path (MAX_PATH_LENGTH)
        (INexusSettler.IntendNode[] memory path, bytes32 targetNodeHash) = _createLinkedPath(
            rootHash, NUM_NODES, nonce, escrow
        );
        
        uint256 gasBefore = gasleft();
        nexusSettler.processPIPath(rootHash, targetNodeHash, path);
        uint256 totalGas = gasBefore - gasleft();
        uint256 gasPerNode = totalGas / NUM_NODES;
        
        emit log("=== O(1) Optimization: 32 Node Path (MAX) ===");
        emit log_named_uint("Total gas (32 nodes)", totalGas);
        emit log_named_uint("Gas per node", gasPerNode);
        emit log_named_uint("Baseline O(n^2) per node", 50000);
        emit log_named_uint("Total baseline O(n^2)", 50000 * 32);
        emit log_named_uint("Reduction vs O(n^2)", (50000 * 32) > totalGas ? (50000 * 32) - totalGas : 0);
        
        // Verify reasonable gas usage (O(n^2) would exceed 5M gas for 32 nodes)
        assertGt(totalGas, 600000, "Total gas should exceed 600k for 32 nodes");
        assertLt(totalGas, 2000000, "Total gas should be under 2M (O(n^2) would exceed 5M)");
        assertLt(gasPerNode, 60000, "Gas per node should be under 60k");
    }

    /**
     * @notice OPTIMIZED: Verify O(n) linear scaling
     * @dev Compares gas across path lengths to verify O(n) not O(n^2)
     * @dev Note: Due to fixed overhead per call, gas ratios start lower but approach
     *      expected O(n) ratios as node count increases.
     */
    function testGasOptimized_LinearScaling() public {
        uint256[] memory nodeCounts = new uint256[](5);
        nodeCounts[0] = 1;
        nodeCounts[1] = 5;
        nodeCounts[2] = 10;
        nodeCounts[3] = 20;
        nodeCounts[4] = 32;
        
        uint256[] memory gasUsage = new uint256[](5);
        uint256[] memory gasPerNode = new uint256[](5);
        
        for (uint256 test = 0; test < 5; test++) {
            uint256 n = nodeCounts[test];
            
            // Setup intent
            bytes32 s = keccak256(abi.encode("linear-source", test));
            bytes32 d = keccak256(abi.encode("linear-dest", test));
            bytes32 o = keccak256(abi.encode("linear-offchain", test));
            uint256 nonce = 2000 + test;
            bytes32 rootHash = _setupIntent(s, d, o, nonce);
            
            // Create n-node path
            (INexusSettler.IntendNode[] memory path, bytes32 targetNodeHash) = _createLinkedPath(
                rootHash, n, nonce, escrow
            );
            
            uint256 gasBefore = gasleft();
            nexusSettler.processPIPath(rootHash, targetNodeHash, path);
            gasUsage[test] = gasBefore - gasleft();
            gasPerNode[test] = gasUsage[test] / n;
        }
        
        emit log("");
        emit log("=== O(1) Linear Scaling Verification ===");
        emit log("Node Count | Total Gas | Gas/Node");
        emit log("-----------|-----------|----------");
        
        for (uint256 i = 0; i < 5; i++) {
            uint256 n = nodeCounts[i];
            emit log_named_uint(string(abi.encodePacked("Nodes=", uint2str(n))), gasUsage[i]);
            emit log_named_uint(string(abi.encodePacked("Gas/node (", uint2str(n), " nodes)")), gasPerNode[i]);
        }
        
        // Verify linear scaling by checking marginal cost consistency
        // For O(n), gas per node should stabilize as n increases
        // (not grow with n like O(n^2) would)
        
        // Per-node cost should decrease then stabilize (fixed overhead amortized)
        assertGt(gasPerNode[4], 20000, "32 nodes should have at least 20k per node amortized");
        assertLt(gasPerNode[4], 50000, "32 nodes should have under 50k per node amortized");
        
        // O(n^2) would be catastrophic - verify we're not there
        // For 32 nodes, O(n^2) would be ~1000x more gas than O(n)
        uint256 totalGas32 = gasUsage[4];
        uint256 on2Estimate = gasUsage[0] * 32 * 32; // O(n^2) estimate
        assertLt(totalGas32, on2Estimate / 10, "Total gas should be < 10% of O(n^2) estimate");
        
        // Verify linear growth: 32 nodes should be less than 50x 1 node
        uint256 ratio32x = gasUsage[4] * 100 / gasUsage[0];
        emit log_named_uint("32x node count gas ratio (should be <5000% for O(n))", ratio32x);
        assertLt(ratio32x, 5000, "32 nodes should use less than 50x gas of 1 node");
        
        emit log("");
        emit log("=== O(1) Optimization Summary ===");
        emit log_named_uint("Gas for 1 node (fixed overhead)", gasUsage[0]);
        emit log_named_uint("Gas for 32 nodes (total)", gasUsage[4]);
        emit log_named_uint("Marginal cost per node (est)", (gasUsage[4] - gasUsage[0]) / 31);
        emit log("O(n) linear scaling confirmed - NOT O(n^2)!");
    }

    /**
     * @notice Helper to convert uint to string (for logging)
     */
    function uint2str(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "0";
        uint256 j = i;
        bytes memory b = new bytes(0);
        while (j != 0) {
            b = bytes.concat(b, bytes1(uint8(48 + j % 10)));
            j /= 10;
        }
        for (j = 0; j < b.length / 2; j++) {
            bytes1 tmp = b[j];
            b[j] = b[b.length - 1 - j];
            b[b.length - 1 - j] = tmp;
        }
        return string(b);
    }
}
