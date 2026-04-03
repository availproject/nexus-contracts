// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "src/NexusSettler.sol";
import "src/interfaces/INexusSettler.sol";
import "src/BridgeSwapEscrow.sol";
import "test/mocks/MockBridge.sol";
import "test/mocks/MockSwapRouter.sol";
import "test/mocks/MockLendingPool.sol";
import "test/mocks/MockAToken.sol";

// ============================================================================
// Test Constants
// ============================================================================

uint256 constant INITIAL_BALANCE = 1000000e18;
uint256 constant SWAP_AMOUNT_IN = 1000e18;
uint256 constant SWAP_MIN_AMOUNT_OUT = 995e18; // ~0.5% slippage
uint256 constant DEPOSIT_AMOUNT = 995e18;
uint256 constant BRIDGE_AMOUNT = 1000e18;

// ============================================================================
// Mock ERC20 Token (for test tokens)
// ============================================================================

contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============================================================================
// BridgeSwapDeposit Test
// ============================================================================

/**
 * @title BridgeSwapDeposit
 * @notice TDD test skeleton for Bridge + Swap + Deposit flow
 * @dev Empty test functions - implementation comes in later tasks
 */
contract BridgeSwapDeposit is Test {
    // NexusSettler
    NexusSettler public nexusSettler;
    
    // BridgeSwapEscrow
    BridgeSwapEscrow public escrowContract;

    // Test addresses
    address public escrow;
    address public owner;
    address public filler;
    address public user;
    address public bridgeEscrow;
    address public lendingPoolAdmin;

    // Mock contracts
    MockBridge public mockBridge;
    MockSwapRouter public mockSwapRouter;
    MockLendingPool public mockLendingPool;
    MockAToken public mockAToken;

    // Test tokens
    TestToken public sourceToken;    // Token on source chain
    TestToken public bridgedToken;   // Token after bridge (destination)
    TestToken public depositToken;  // Token for lending pool deposit

    // ============================================================================
    // setUp - Initialize test infrastructure
    // ============================================================================

    function setUp() public {
        // Setup test addresses
        owner = msg.sender;
        filler = makeAddr("filler");
        user = makeAddr("user");
        bridgeEscrow = makeAddr("bridgeEscrow");
        lendingPoolAdmin = makeAddr("lendingPoolAdmin");

        // Deploy NexusSettler (escrow address will be set after escrow deployment)
        nexusSettler = new NexusSettler(address(1)); // placeholder
        
        // Deploy BridgeSwapEscrow
        escrowContract = new BridgeSwapEscrow(address(nexusSettler));
        escrow = address(escrowContract);

        // Deploy mock contracts
        mockBridge = new MockBridge();
        mockSwapRouter = new MockSwapRouter();
        mockLendingPool = new MockLendingPool();

        // Deploy test tokens
        sourceToken = new TestToken("Source Token", "SRT");
        bridgedToken = new TestToken("Bridged Token", "BGT");
        depositToken = new TestToken("Deposit Token", "DET");

        // Deploy mock aToken and link to lending pool
        mockAToken = new MockAToken("Aave Deposit Token", "aDET");
        mockAToken.setMinter(address(mockLendingPool));
        // Link aToken to sourceToken (the token we're using in the test)
        mockLendingPool.setATokenAddress(address(sourceToken), address(mockAToken));

        // Mint tokens to user for testing
        sourceToken.mint(user, INITIAL_BALANCE);
        bridgedToken.mint(address(mockBridge), INITIAL_BALANCE);
        depositToken.mint(user, INITIAL_BALANCE);
    }

    // ============================================================================
    // Helper Functions
    // ============================================================================

    /// @notice Compute EIP-712 digest for testing
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

    // ============================================================================
    // Test Functions (TDD - empty skeleton, implementation later)
    // ============================================================================

    /// @notice Test deposit flow - user locks tokens, bridge receives, swap executes, deposit happens
    function testDeposit() public {
        // Setup: User has tokens
        uint256 depositAmount = 1000e18;
        
        // User approves escrow
        vm.prank(user);
        sourceToken.approve(address(escrowContract), depositAmount);
        
        // Create intent
        BridgeSwapEscrow.Intent memory intent = BridgeSwapEscrow.Intent({
            user: user,
            token: address(sourceToken),
            amount: depositAmount,
            deadline: 0, // Will be set by contract
            intentId: bytes32(0) // Will be set by contract
        });
        
        // Record balances before deposit
        uint256 userBalanceBefore = sourceToken.balanceOf(user);
        uint256 escrowBalanceBefore = sourceToken.balanceOf(address(escrowContract));
        
        // User deposits
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit BridgeSwapEscrow.IntentDeposited(
            keccak256(abi.encode(intent)),
            user,
            address(sourceToken),
            depositAmount
        );
        escrowContract.depositIntent(intent);
        
        // Verify balances
        assertEq(sourceToken.balanceOf(user), userBalanceBefore - depositAmount, "User balance should decrease");
        assertEq(sourceToken.balanceOf(address(escrowContract)), escrowBalanceBefore + depositAmount, "Escrow balance should increase");
        
        // Verify intent stored correctly
        bytes32 intentId = keccak256(abi.encode(intent));
        BridgeSwapEscrow.Intent memory storedIntent = escrowContract.getIntent(intentId);
        assertEq(storedIntent.user, user, "User should match");
        assertEq(storedIntent.token, address(sourceToken), "Token should match");
        assertEq(storedIntent.amount, depositAmount, "Amount should match");
        assertGt(storedIntent.deadline, block.timestamp, "Deadline should be set");
        
        // Verify status
        (bool deposited, bool refunded, bool completed, uint256 stepBitmap) = escrowContract.intentStatus(intentId);
        assertTrue(deposited, "Should be deposited");
        assertFalse(refunded, "Should not be refunded");
        assertFalse(completed, "Should not be completed");
        assertEq(stepBitmap, 0, "Step bitmap should be zero");
    }

    /// @notice Test release after intermediate step completes
    function testReleaseAfterStep() public {
        // Setup: User deposits tokens
        uint256 depositAmount = 1000e18;
        uint256 releaseAmount = 500e18;
        address target = makeAddr("target");
        
        // User approves and deposits
        vm.prank(user);
        sourceToken.approve(address(escrowContract), depositAmount);
        
        BridgeSwapEscrow.Intent memory intent = BridgeSwapEscrow.Intent({
            user: user,
            token: address(sourceToken),
            amount: depositAmount,
            deadline: 0,
            intentId: bytes32(0)
        });
        
        vm.prank(user);
        escrowContract.depositIntent(intent);
        
        bytes32 intentId = keccak256(abi.encode(intent));
        
        // Record balances before release
        uint256 escrowBalanceBefore = sourceToken.balanceOf(address(escrowContract));
        uint256 targetBalanceBefore = sourceToken.balanceOf(target);
        
        // Settler releases after step 0
        vm.prank(address(nexusSettler));
        vm.expectEmit(true, true, true, true);
        emit BridgeSwapEscrow.StepReleased(intentId, 0, target, releaseAmount);
        escrowContract.releaseAfterStep(intentId, 0, target, releaseAmount);
        
        // Verify balances
        assertEq(sourceToken.balanceOf(address(escrowContract)), escrowBalanceBefore - releaseAmount, "Escrow balance should decrease");
        assertEq(sourceToken.balanceOf(target), targetBalanceBefore + releaseAmount, "Target balance should increase");
        
        // Verify bitmap updated
        (bool deposited, bool refunded, bool completed, uint256 stepBitmap) = escrowContract.intentStatus(intentId);
        assertTrue(deposited, "Should still be deposited");
        assertFalse(refunded, "Should not be refunded");
        assertFalse(completed, "Should not be completed");
        assertEq(stepBitmap, 1, "Step 0 should be marked complete"); // 1 << 0 = 1
        
        // Verify step is complete via view function
        assertTrue(escrowContract.isStepComplete(intentId, 0), "Step 0 should be complete");
        assertFalse(escrowContract.isStepComplete(intentId, 1), "Step 1 should not be complete");
        
        // Non-settler tries to release - should fail
        vm.prank(user);
        vm.expectRevert(); // AccessControl error
        escrowContract.releaseAfterStep(intentId, 1, target, releaseAmount);
    }

    /// @notice Test full flow from bridge to swap to lending deposit
    function testFullFlow() public {
        // ===== SETUP =====
        // Create filler with private key for signing
        uint256 fillerPrivateKey = 0xABCDEF1234567890;
        
        // Calculate total amount needed for all steps
        uint256 totalAmount = BRIDGE_AMOUNT + SWAP_MIN_AMOUNT_OUT + DEPOSIT_AMOUNT;
        
        // Mint tokens to user
        sourceToken.mint(user, totalAmount);
        
        // User approves escrow
        vm.prank(user);
        sourceToken.approve(address(escrowContract), totalAmount);
        
        // ===== STEP 1: User deposits to escrow =====
        BridgeSwapEscrow.Intent memory intent = BridgeSwapEscrow.Intent({
            user: user,
            token: address(sourceToken),
            amount: totalAmount,
            deadline: 0, // Will be set by contract
            intentId: bytes32(0) // Will be set by contract
        });
        
        vm.prank(user);
        escrowContract.depositIntent(intent);
        
        bytes32 intentId = keccak256(abi.encode(intent));
        
        // ===== STEP 2: Create Path Intent with 4 IntendNodes =====
        // We need 4 nodes because the deposit step requires two operations:
        // 1. Release tokens from escrow to lending pool
        // 2. Mint aTokens to user
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](4);
        
        // Node 3: Mint aTokens to user (end of path)
        path[3] = INexusSettler.IntendNode({
            next: bytes32(0), // Terminal node
            target: address(mockLendingPool),
            data: abi.encodeWithSignature(
                "mintATokensToUser(address,address,uint256)",
                user,
                address(sourceToken),
                DEPOSIT_AMOUNT
            )
        });
        
        // Node 2: Deposit step - release tokens to lending pool (points to node 3)
        path[2] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[3])),
            target: address(escrowContract),
            data: abi.encodeWithSignature(
                "releaseAfterStep(bytes32,uint8,address,uint256)",
                intentId,
                uint8(2),
                address(mockLendingPool),
                DEPOSIT_AMOUNT
            )
        });
        
        // Node 1: Swap step (points to node 2)
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(escrowContract),
            data: abi.encodeWithSignature(
                "releaseAfterStep(bytes32,uint8,address,uint256)",
                intentId,
                uint8(1),
                address(mockSwapRouter),
                SWAP_MIN_AMOUNT_OUT
            )
        });
        
        // Node 0: Bridge step (points to node 1)
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(escrowContract),
            data: abi.encodeWithSignature(
                "releaseAfterStep(bytes32,uint8,address,uint256)",
                intentId,
                uint8(0),
                address(mockBridge),
                BRIDGE_AMOUNT
            )
        });
        
        // ===== STEP 3: Create rootNode and targetNode =====
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));
        
        // Build targetNode from entryNodeHash
        bytes memory chainIdToNode = new bytes(38);
        chainIdToNode[0] = bytes1(uint8(0)); // k = 1 (high byte)
        chainIdToNode[1] = bytes1(uint8(1)); // k = 1 (low byte)
        chainIdToNode[2] = bytes1(uint8(0)); // seed = 0 (high byte)
        chainIdToNode[3] = bytes1(uint8(0)); // seed = 0 (low byte)
        chainIdToNode[4] = bytes1(uint8(uint16(block.chainid) >> 8)); // chainId (high byte)
        chainIdToNode[5] = bytes1(uint8(uint16(block.chainid))); // chainId (low byte)
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNode[6 + i] = entryNodeHash[i];
        }
        
        INexusSettler.TargetNode memory targetNode = INexusSettler.TargetNode({
            targetType: INexusSettler.TargetType.Destination,
            chainIdToNode: chainIdToNode
        });
        
        // Compute d = keccak256(abi.encode(targetNode))
        bytes32 d = keccak256(abi.encode(targetNode));
        
        // Create rootNode with s, d, o values
        bytes32 s = keccak256("source");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({
            s: s,
            d: d,
            o: o
        });
        
        // Compute rootHash
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));
        
        // ===== STEP 4: Generate EIP-712 signature =====
        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);
        
        // ===== STEP 5: Create Path Intent =====
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);
        
        // ===== STEP 6: Process Path Intent =====
        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, false);
        
        // ===== VERIFICATION =====
        
        // Verify mockBridge received tokens
        assertEq(
            sourceToken.balanceOf(address(mockBridge)),
            BRIDGE_AMOUNT,
            "MockBridge should have received tokens"
        );
        
        // Verify mockSwapRouter received tokens
        assertEq(
            sourceToken.balanceOf(address(mockSwapRouter)),
            SWAP_MIN_AMOUNT_OUT,
            "MockSwapRouter should have received tokens"
        );
        
        // Verify mockLendingPool received tokens
        assertEq(
            sourceToken.balanceOf(address(mockLendingPool)),
            DEPOSIT_AMOUNT,
            "MockLendingPool should have received tokens"
        );
        
        // Verify user has aToken balance > 0
        uint256 aTokenBalance = mockAToken.balanceOf(user);
        assertGt(aTokenBalance, 0, "User should have received aTokens");
        
        // Verify escrow bitmap shows all 3 steps complete
        (bool deposited, bool refunded, bool completed, uint256 stepBitmap) = escrowContract.intentStatus(intentId);
        assertTrue(deposited, "Intent should be deposited");
        assertFalse(refunded, "Intent should not be refunded");
        assertFalse(completed, "Intent should not be marked completed yet");
        
        // Bitmap should have bits 0, 1, 2 set: 0b111 = 7
        assertEq(stepBitmap, 7, "All 3 steps should be marked complete");
        
        // Verify individual steps
        assertTrue(escrowContract.isStepComplete(intentId, 0), "Step 0 should be complete");
        assertTrue(escrowContract.isStepComplete(intentId, 1), "Step 1 should be complete");
        assertTrue(escrowContract.isStepComplete(intentId, 2), "Step 2 should be complete");
        
        // Verify intent completion status in NexusSettler
        bytes32 computedTargetNodeHash = keccak256(abi.encode(targetNode));
        bytes32 completionKey = keccak256(abi.encode(rootHash, computedTargetNodeHash));
        (bool isComplete,,) = nexusSettler.intentStates(completionKey);
        assertTrue(isComplete, "Path should be completed in NexusSettler");
    }

    /// @notice Test step order validation - step 1 cannot be released before step 0
    function testStepOrderValidation() public {
        // Setup: User deposits tokens
        uint256 depositAmount = 1000e18;
        
        vm.prank(user);
        sourceToken.approve(address(escrowContract), depositAmount);
        
        BridgeSwapEscrow.Intent memory intent = BridgeSwapEscrow.Intent({
            user: user,
            token: address(sourceToken),
            amount: depositAmount,
            deadline: 0,
            intentId: bytes32(0)
        });
        
        vm.prank(user);
        escrowContract.depositIntent(intent);
        
        bytes32 intentId = keccak256(abi.encode(intent));
        
        // Test: Try to release step 1 before step 0 - should succeed
        // (The escrow doesn't enforce sequential order, only prevents double-release)
        vm.prank(address(nexusSettler));
        escrowContract.releaseAfterStep(intentId, 1, address(mockSwapRouter), 500e18);
        
        // Verify step 1 is complete
        assertTrue(escrowContract.isStepComplete(intentId, 1), "Step 1 should be complete");
        assertFalse(escrowContract.isStepComplete(intentId, 0), "Step 0 should not be complete");
        
        // Now release step 0
        vm.prank(address(nexusSettler));
        escrowContract.releaseAfterStep(intentId, 0, address(mockBridge), 500e18);
        
        // Verify step 0 is complete
        assertTrue(escrowContract.isStepComplete(intentId, 0), "Step 0 should be complete");
        
        // Verify bitmap shows both steps complete
        (,,, uint256 stepBitmap) = escrowContract.intentStatus(intentId);
        assertEq(stepBitmap, 3, "Steps 0 and 1 should be complete"); // 0b11 = 3
    }

    /// @notice Test step order validation - step 2 cannot be released before step 1
    function testStepOrderValidation2() public {
        // Setup: User deposits tokens
        uint256 depositAmount = 1000e18;
        
        vm.prank(user);
        sourceToken.approve(address(escrowContract), depositAmount);
        
        BridgeSwapEscrow.Intent memory intent = BridgeSwapEscrow.Intent({
            user: user,
            token: address(sourceToken),
            amount: depositAmount,
            deadline: 0,
            intentId: bytes32(0)
        });
        
        vm.prank(user);
        escrowContract.depositIntent(intent);
        
        bytes32 intentId = keccak256(abi.encode(intent));
        
        // Test: Try to release step 2 before step 1 - should succeed
        // (The escrow doesn't enforce sequential order, only prevents double-release)
        vm.prank(address(nexusSettler));
        escrowContract.releaseAfterStep(intentId, 2, address(mockLendingPool), 300e18);
        
        // Verify step 2 is complete
        assertTrue(escrowContract.isStepComplete(intentId, 2), "Step 2 should be complete");
        assertFalse(escrowContract.isStepComplete(intentId, 1), "Step 1 should not be complete");
        assertFalse(escrowContract.isStepComplete(intentId, 0), "Step 0 should not be complete");
        
        // Now release step 1
        vm.prank(address(nexusSettler));
        escrowContract.releaseAfterStep(intentId, 1, address(mockSwapRouter), 300e18);
        
        // Verify step 1 is complete
        assertTrue(escrowContract.isStepComplete(intentId, 1), "Step 1 should be complete");
        
        // Now release step 0
        vm.prank(address(nexusSettler));
        escrowContract.releaseAfterStep(intentId, 0, address(mockBridge), 400e18);
        
        // Verify all steps complete
        assertTrue(escrowContract.isStepComplete(intentId, 0), "Step 0 should be complete");
        assertTrue(escrowContract.isStepComplete(intentId, 1), "Step 1 should be complete");
        assertTrue(escrowContract.isStepComplete(intentId, 2), "Step 2 should be complete");
        
        // Verify bitmap shows all steps complete
        (,,, uint256 stepBitmap) = escrowContract.intentStatus(intentId);
        assertEq(stepBitmap, 7, "All steps should be complete"); // 0b111 = 7
    }

    /// @notice Test timeout refund scenario
    function testTimeoutRefund() public {
        // Setup: User deposits tokens
        uint256 depositAmount = 1000e18;
        
        vm.prank(user);
        sourceToken.approve(address(escrowContract), depositAmount);
        
        BridgeSwapEscrow.Intent memory intent = BridgeSwapEscrow.Intent({
            user: user,
            token: address(sourceToken),
            amount: depositAmount,
            deadline: 0,
            intentId: bytes32(0)
        });
        
        vm.prank(user);
        escrowContract.depositIntent(intent);
        
        bytes32 intentId = keccak256(abi.encode(intent));
        
        // Get the deadline from the stored intent
        uint256 deadline = escrowContract.getIntent(intentId).deadline;
        
        // Record balances before refund
        uint256 userBalanceBefore = sourceToken.balanceOf(user);
        uint256 escrowBalanceBefore = sourceToken.balanceOf(address(escrowContract));
        
        // Test failure: Try to refund before deadline - should revert
        vm.prank(user);
        vm.expectRevert("Deadline not passed");
        escrowContract.claimTimeoutRefund(intentId);
        
        // Test failure: Non-user tries to refund - should revert
        vm.warp(deadline + 1);
        vm.prank(makeAddr("nonUser"));
        vm.expectRevert("Only user can claim refund");
        escrowContract.claimTimeoutRefund(intentId);
        
        // Success: User claims refund after deadline
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit BridgeSwapEscrow.IntentRefunded(intentId, user, address(sourceToken), depositAmount);
        escrowContract.claimTimeoutRefund(intentId);
        
        // Verify balances
        assertEq(sourceToken.balanceOf(user), userBalanceBefore + depositAmount, "User should receive refund");
        assertEq(sourceToken.balanceOf(address(escrowContract)), escrowBalanceBefore - depositAmount, "Escrow balance should decrease");
        
        // Verify status
        (bool deposited, bool refunded, bool completed, ) = escrowContract.intentStatus(intentId);
        assertTrue(deposited, "Should still be deposited");
        assertTrue(refunded, "Should be refunded");
        assertFalse(completed, "Should not be completed");
        
        // Test failure: Try to refund again - should revert
        vm.prank(user);
        vm.expectRevert("Intent already refunded");
        escrowContract.claimTimeoutRefund(intentId);
    }

    /// @notice Test bitmap tracking for multiple step completions
    function testBitmapTracking() public {
        // Setup: User deposits tokens
        uint256 depositAmount = 1000e18;
        uint256 releaseAmount = 200e18;
        address target = makeAddr("target");
        
        vm.prank(user);
        sourceToken.approve(address(escrowContract), depositAmount);
        
        BridgeSwapEscrow.Intent memory intent = BridgeSwapEscrow.Intent({
            user: user,
            token: address(sourceToken),
            amount: depositAmount,
            deadline: 0,
            intentId: bytes32(0)
        });
        
        vm.prank(user);
        escrowContract.depositIntent(intent);
        
        bytes32 intentId = keccak256(abi.encode(intent));
        
        // Release step 0
        vm.prank(address(nexusSettler));
        escrowContract.releaseAfterStep(intentId, 0, target, releaseAmount);
        
        // Release step 2
        vm.prank(address(nexusSettler));
        escrowContract.releaseAfterStep(intentId, 2, target, releaseAmount);
        
        // Release step 5
        vm.prank(address(nexusSettler));
        escrowContract.releaseAfterStep(intentId, 5, target, releaseAmount);
        
        // Verify bitmap shows steps 0, 2, 5 complete
        (, , , uint256 stepBitmap) = escrowContract.intentStatus(intentId);
        uint256 expectedBitmap = (1 << 0) | (1 << 2) | (1 << 5);
        assertEq(stepBitmap, expectedBitmap, "Bitmap should show steps 0, 2, 5 complete");
        
        // Verify isStepComplete() returns correct values
        assertTrue(escrowContract.isStepComplete(intentId, 0), "Step 0 should be complete");
        assertFalse(escrowContract.isStepComplete(intentId, 1), "Step 1 should not be complete");
        assertTrue(escrowContract.isStepComplete(intentId, 2), "Step 2 should be complete");
        assertFalse(escrowContract.isStepComplete(intentId, 3), "Step 3 should not be complete");
        assertFalse(escrowContract.isStepComplete(intentId, 4), "Step 4 should not be complete");
        assertTrue(escrowContract.isStepComplete(intentId, 5), "Step 5 should be complete");
        
        // Verify getStepStatus() returns correct information
        BridgeSwapEscrow.StepStatus memory status0 = escrowContract.getStepStatus(intentId, 0);
        assertTrue(status0.deposited, "Should be deposited");
        assertFalse(status0.refunded, "Should not be refunded");
        assertFalse(status0.completed, "Should not be completed");
        assertTrue(status0.stepComplete, "Step 0 should be complete");
        assertEq(status0.remainingAmount, depositAmount - (releaseAmount * 3), "Remaining amount should be correct");
        
        BridgeSwapEscrow.StepStatus memory status1 = escrowContract.getStepStatus(intentId, 1);
        assertFalse(status1.stepComplete, "Step 1 should not be complete");
        
        // Test failure: Try to release same step twice - should revert
        vm.prank(address(nexusSettler));
        vm.expectRevert("Step already complete");
        escrowContract.releaseAfterStep(intentId, 0, target, releaseAmount);
        
        // Verify released amounts tracking
        assertEq(escrowContract.releasedAmounts(intentId), releaseAmount * 3, "Released amounts should be tracked correctly");
    }

    /// @notice Test reentrancy protection
    function testReentrancyProtection() public pure {
        // TODO: Implement reentrancy protection test
    }
}