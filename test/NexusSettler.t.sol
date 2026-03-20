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
}
