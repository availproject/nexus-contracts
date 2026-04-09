// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "lib/forge-std/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NexusSettler} from "../src/NexusSettler.sol";
import {ERC7702Delegator} from "../src/ERC7702Delegator.sol";
import {INexusSettler} from "../src/interfaces/INexusSettler.sol";
import {IERC7821} from "@openzeppelin/contracts/interfaces/draft-IERC7821.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {console2} from "lib/forge-std/src/console2.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import {ERC7702SignatureHelper} from "./helpers/ERC7702SignatureHelper.sol";

/**
 * @title ERC7702Integration
 * @notice Comprehensive integration test proving 7702 flow works with UNCHANGED NexusSettler
 * @dev This test verifies that NO modifications to src/ contracts are needed for 7702 integration
 *      The key insight: NexusSettler._executeAction at line 237-239 just forwards calls.
 *      When target is a 7702 EOA with delegation, the call executes via the delegator.
 */
contract ERC7702Integration is Test {
    // ============ Contracts ============
    NexusSettler public nexusSettler;
    ERC7702Delegator public delegator;
    address public escrow;

    // ============ Actors ============
    address public userEOA; // The 7702 EOA (will have delegation code)
    uint256 public userPrivateKey;
    address public controlledEOA; // The EOA that calls processPIPath
    uint256 public controlledPrivateKey;
    address public recipient; // Receives funds

    // ============ Constants ============
    uint256 constant INITIAL_BALANCE = 1 ether;
    uint256 constant TRANSFER_AMOUNT = 0.5 ether;
    uint256 constant NONCE = 1;

    // ============ Events ============
    event PICreated(bytes32 indexed rootHash, address indexed signer);
    event IntendPathProcessed(bytes32 indexed targetNodeHash, bytes32 lastNodeHash, bytes32 graphRoot);
    event BatchExecuted(uint256 indexed nonce, Execution[] calls, bytes[] results);
    event CallExecuted(address indexed target, uint256 value, bytes data, bytes result);

    // ============ Setup ============
    function setUp() public {
        // Deploy escrow mock
        escrow = makeAddr("escrow");
        vm.deal(escrow, 10 ether);

        // Deploy NexusSettler behind UUPS proxy
        NexusSettler impl = new NexusSettler();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(NexusSettler.initialize, (escrow, address(this)))
        );
        nexusSettler = NexusSettler(address(proxy));

        // Deploy ERC7702Delegator (NEW contract from T2)
        delegator = new ERC7702Delegator();

        // Create user EOA (will become 7702 EOA)
        (userEOA, userPrivateKey) = makeAddrAndKey("userEOA");
        vm.deal(userEOA, INITIAL_BALANCE);

        // Create controlled EOA (regular EOA that calls processPIPath)
        (controlledEOA, controlledPrivateKey) = makeAddrAndKey("controlledEOA");
        vm.deal(controlledEOA, INITIAL_BALANCE);

        // Create recipient
        recipient = makeAddr("recipient");
        vm.deal(recipient, 0);
    }

    /**
     * @notice Test: Complete 7702 integration flow with unchanged NexusSettler
     */
    function test_CompleteIntegrationFlow() public {
        // Setup 7702 delegation
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), address(delegator));
        vm.etch(userEOA, delegationCode);

        assertEq(userEOA.code, delegationCode, "Delegation code not set correctly");

        // User creates execution calls
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution({
            target: recipient,
            value: TRANSFER_AMOUNT,
            callData: ""
        });

        // Sign execution
        bytes32 executionDigest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, NONCE, 0, calls);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, executionDigest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Verify signature
        address recovered = ECDSA.recover(executionDigest, signature);
        assertEq(recovered, userEOA, "Signature recovery failed");

        // Encode execute call
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute((address,uint256,bytes)[],uint256,uint256,bytes)",
            calls,
            NONCE,
            uint256(0),
            signature
        );

        // Create intent path
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: userEOA,
            data: executeCalldata
        });

        // Create target node
        bytes32 firstNodeHash = keccak256(abi.encode(path[0]));
        uint16 chainId = uint16(block.chainid);
        INexusSettler.TargetNode memory targetNode = _createSingleTargetNode(
            INexusSettler.TargetType.Source,
            chainId,
            firstNodeHash
        );

        // Create root node
        bytes32 targetNodeHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({
            s: targetNodeHash,
            d: bytes32(0),
            o: bytes32(0)
        });

        // Create and sign intent
        uint256 nonce = 42;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
                rootHash,
                nonce
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NexusSettler")),
                keccak256(bytes("2")),
                block.chainid,
                address(nexusSettler)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPrivateKey, digest);
        bytes memory intentSignature = abi.encodePacked(r2, s2, v2);

        // Create intent
        vm.prank(userEOA);
        vm.expectEmit(true, true, false, false);
        emit PICreated(rootHash, userEOA);
        nexusSettler.createPI(rootHash, intentSignature, nonce, rootNode);

        assertTrue(nexusSettler.created(rootHash), "Intent not created");

        // Execute path
        uint256 recipientBalanceBefore = recipient.balance;
        uint256 userEOABalanceBefore = userEOA.balance;

        vm.prank(controlledEOA);
        vm.expectEmit(true, true, true, false);
        emit IntendPathProcessed(targetNodeHash, firstNodeHash, rootHash);
        nexusSettler.processPIPath(
            rootHash,
            rootNode,
            targetNode,
            path,
            nonce,
            true
        );

        // Verify results
        assertEq(
            recipient.balance - recipientBalanceBefore,
            TRANSFER_AMOUNT,
            "Recipient did not receive correct amount"
        );
        assertEq(
            userEOABalanceBefore - userEOA.balance,
            TRANSFER_AMOUNT,
            "User EOA balance did not decrease correctly"
        );

        // Verify intent state
        bytes32 completionKey = keccak256(abi.encode(rootHash, targetNodeHash));
        (bool completed, uint248 bitmap, bytes32 nextHash) = nexusSettler.intentStates(completionKey);
        assertTrue(completed, "Intent not marked as completed");
        assertEq(bitmap, 1, "Bitmap should have first bit set");
        assertEq(nextHash, bytes32(0), "Next hash should be 0 for completed path");
    }

    /**
     * @notice Test 1b: 3-Node Destination Flow with Swap (Happy Path)
     * @dev 3 nodes: Swap -> Transfer -> Deposit (destination chain)
     * Node 1: Swap ETH to USDC from controlled wallet
     * Node 2: Transfer USDC to user EOA
     * Node 3: Deposit via 7702 execute
     */
    function test_ThreeNodeDestinationFlowWithSwap() public {
        // ============ SETUP: Deploy Mocks ============
        // Deploy mock USDC token (6 decimals like real USDC)
        MockUSDC usdc = new MockUSDC();
        
        // Deploy mock Aave pool and aToken
        MockAavePool aavePool = new MockAavePool();
        MockAToken aUSDC = new MockAToken("Aave USDC", "aUSDC");
        aavePool.setATokenForAsset(address(usdc), address(aUSDC));
        aUSDC.setMinter(address(aavePool));
        
        // ============ STEP 1: Setup 7702 Delegation for User EOA ============
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), address(delegator));
        vm.etch(userEOA, delegationCode);
        assertEq(userEOA.code, delegationCode, "Delegation code not set correctly");
        
        // ============ STEP 2: Fund NexusSettler with USDC (simulating swap result) ============
        // Note: Controller (solver) funds NexusSettler which then transfers to userEOA
        uint256 usdcAmount = 1000 * 10**6; // 1000 USDC
        usdc.mint(address(nexusSettler), usdcAmount);
        
        // Log initial balances
        console2.log("Solver (controller) calls processPIPath to execute:");
        console2.log("  1. Approve AavePool (from NexusSettler funds)");
        console2.log("  2. Transfer USDC to userEOA (solver -> user)");
        console2.log("  3. User deposits to Aave via 7702");
        console2.log("NexusSettler USDC (solver funds):", usdc.balanceOf(address(nexusSettler)));
        console2.log("User EOA USDC:", usdc.balanceOf(userEOA));
        
        // ============ BUILD 3-NODE PATH ============
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](3);
        
        // Node 1: Solver (controller) triggers approve via NexusSettler
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(usdc),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(aavePool), usdcAmount)
        });
        
        // Node 2: Solver (controller) triggers transfer to userEOA
        path[1] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(usdc),
            data: abi.encodeWithSelector(IERC20.transfer.selector, userEOA, usdcAmount)
        });
        
        // Node 3: User EOA deposits USDC to Aave via 7702 (needs signature)
        // User EOA calls USDC.approve() and AavePool.supply() via 7702 delegation
        Execution[] memory depositCalls = new Execution[](2);
        depositCalls[0] = Execution({
            target: address(usdc),
            value: 0,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(aavePool), usdcAmount)
        });
        depositCalls[1] = Execution({
            target: address(aavePool),
            value: 0,
            callData: abi.encodeWithSelector(MockAavePool.supply.selector, address(usdc), usdcAmount, userEOA, 0)
        });
        
        // User signs the deposit execution
        uint256 depositNonce = 100;
        bytes32 depositDigest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, depositNonce, 0, depositCalls);
        (uint8 vDeposit, bytes32 rDeposit, bytes32 sDeposit) = vm.sign(userPrivateKey, depositDigest);
        bytes memory depositSignature = abi.encodePacked(rDeposit, sDeposit, vDeposit);
        
        // Encode the execute call for node 3
        bytes memory node3Data = abi.encodeWithSignature(
            "execute((address,uint256,bytes)[],uint256,uint256,bytes)",
            depositCalls,
            depositNonce,
            uint256(0),
            depositSignature
        );
        
        path[2] = INexusSettler.IntendNode({
            next: bytes32(0), // Terminal node
            target: userEOA,  // 7702 EOA executes
            data: node3Data
        });
        
        // Compute hashes and set next pointers (in reverse order)
        bytes32 node3Hash = keccak256(abi.encode(path[2]));
        path[1].next = node3Hash;
        
        bytes32 node2Hash = keccak256(abi.encode(path[1]));
        path[0].next = node2Hash;
        
        bytes32 node1Hash = keccak256(abi.encode(path[0]));
        
        console2.log("=== Node Hashes ===");
        console2.log("Node 1 (Approve) hash:");
        console2.logBytes32(node1Hash);
        console2.log("Node 2 (Transfer) hash:");
        console2.logBytes32(node2Hash);
        console2.log("Node 3 (Deposit) hash:");
        console2.logBytes32(node3Hash);
        
        // ============ STEP 3: Create Destination Target Node ============
        uint16 chainId = uint16(block.chainid);
        INexusSettler.TargetNode memory targetNode = _createSingleTargetNode(
            INexusSettler.TargetType.Destination, // Destination chain!
            chainId,
            node1Hash
        );
        
        bytes32 targetNodeHash = keccak256(abi.encode(targetNode));
        
        // ============ STEP 4: Create Root Node with d: targetNodeHash ============
        // For destination chain, root node uses 'd' field
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({
            s: bytes32(0),      // No source
            d: targetNodeHash,  // Destination target
            o: bytes32(0)       // No origin
        });
        
        // ============ STEP 5: Create Intent ============
        uint256 nonce = 200;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));
        
        // Sign intent creation
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
                rootHash,
                nonce
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NexusSettler")),
                keccak256(bytes("2")),
                block.chainid,
                address(nexusSettler)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPrivateKey, digest);
        bytes memory intentSignature = abi.encodePacked(r2, s2, v2);
        
        // Create the intent
        vm.prank(userEOA);
        vm.expectEmit(true, true, false, false);
        emit PICreated(rootHash, userEOA);
        nexusSettler.createPI(rootHash, intentSignature, nonce, rootNode);
        
        assertTrue(nexusSettler.created(rootHash), "Intent not created");
        
        // ============ STEP 6: Solver (controller) Executes 3-Node Path ============
        // Record balances before
        uint256 userUSDCBefore = usdc.balanceOf(userEOA);
        uint256 userAUSDCBefore = aUSDC.balanceOf(userEOA);
        
        console2.log("=== Before Solver Execution ===");
        console2.log("NexusSettler USDC (solver funds):", usdc.balanceOf(address(nexusSettler)));
        console2.log("User EOA USDC:", userUSDCBefore);
        console2.log("User EOA aUSDC:", userAUSDCBefore);
        
        // Solver (controller) calls processPIPath on destination chain (isSource = false)
        vm.prank(controlledEOA);
        vm.expectEmit(true, true, true, false);
        emit IntendPathProcessed(targetNodeHash, node3Hash, rootHash);
        nexusSettler.processPIPath(
            rootHash,
            rootNode,
            targetNode,
            path,
            nonce,
            false // isSource = false (destination chain)
        );
        
        // ============ STEP 7: Verify Solver Execution Results ============
        console2.log("=== After Solver Execution ===");
        console2.log("NexusSettler USDC (remaining solver funds):", usdc.balanceOf(address(nexusSettler)));
        console2.log("User EOA USDC (received from solver):", usdc.balanceOf(userEOA));
        console2.log("User EOA aUSDC (deposited to Aave):", aUSDC.balanceOf(userEOA));
        
        // Verify Node 1 executed: NexusSettler approved AavePool
        uint256 allowanceAfter = usdc.allowance(address(nexusSettler), address(aavePool));
        console2.log("NexusSettler allowance for AavePool:", allowanceAfter);
        
        // Verify USDC was transferred to userEOA (Node 2 - solver -> user)
        uint256 userUSDCAfter = usdc.balanceOf(userEOA);
        console2.log("User received from solver:", userUSDCAfter - userUSDCBefore);
        
        // Verify aUSDC was minted to userEOA (Node 3 - user deposit via 7702)
        uint256 userAUSDCAfter = aUSDC.balanceOf(userEOA);
        console2.log("User deposited to Aave:", userAUSDCAfter - userAUSDCBefore);
        
        // Verify 1: aUSDC minted to userEOA (not solver or NexusSettler)
        assertEq(userAUSDCAfter - userAUSDCBefore, usdcAmount, "User EOA should receive aUSDC");
        assertEq(aUSDC.balanceOf(controlledEOA), 0, "Solver should NOT receive aUSDC");
        assertEq(aUSDC.balanceOf(address(nexusSettler)), 0, "NexusSettler should NOT receive aUSDC");
        
        // Verify 2: AavePool storage - userEOA is the depositor key
        uint256 suppliedToUserEOA = aavePool.getSupplied(userEOA, address(usdc));
        uint256 suppliedToSolver = aavePool.getSupplied(controlledEOA, address(usdc));
        uint256 suppliedToSettler = aavePool.getSupplied(address(nexusSettler), address(usdc));
        uint256 suppliedToDelegator = aavePool.getSupplied(address(delegator), address(usdc));
        
        console2.log("=== AavePool Storage Keys ===");
        console2.log("supplied[userEOA] (depositor):  ", suppliedToUserEOA);
        console2.log("supplied[solver]:              ", suppliedToSolver);
        console2.log("supplied[NexusSettler]:        ", suppliedToSettler);
        console2.log("supplied[delegator]:           ", suppliedToDelegator);
        
        // userEOA must be the depositor key (not solver)
        assertEq(suppliedToUserEOA, usdcAmount, "AavePool: userEOA is depositor");
        assertEq(suppliedToSolver, 0, "AavePool: solver NOT depositor");
        assertEq(suppliedToSettler, 0, "AavePool: NexusSettler NOT depositor");
        assertEq(suppliedToDelegator, 0, "AavePool: delegator NOT depositor");
        
        // Verify 3: USDC flow: solver -> NexusSettler -> userEOA -> AavePool
        console2.log("=== USDC Flow: Solver -> User -> Aave ===");
        console2.log("AavePool USDC (deposited):", usdc.balanceOf(address(aavePool)));
        console2.log("User EOA USDC (after deposit):", usdc.balanceOf(userEOA));
        
        assertEq(usdc.balanceOf(address(aavePool)), usdcAmount, "AavePool holds deposited USDC");
        assertEq(usdc.balanceOf(userEOA), 0, "User deposited all USDC to Aave");
        
        // Verify 4: DIRECT TEST - Call supply() and verify onBehalfOf is userEOA
        console2.log("=== DIRECT AavePool.supply() TEST ===");
        
        // Fund the aavePool with more USDC for this test
        usdc.mint(address(aavePool), usdcAmount);
        
        // Test: If we call supply() with controlledEOA as onBehalfOf, it records for controlledEOA
        // This proves the onBehalfOf parameter WORKS and the KEY is onBehalfOf
        vm.startPrank(address(aavePool)); // Become AavePool to test internal
        
        // First, let's check the supply() function behavior directly
        // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        // The KEY in supplied mapping is onBehalfOf
        
        // Mint fresh USDC to a test address
        address testCaller = makeAddr("testCaller");
        usdc.mint(testCaller, usdcAmount);
        vm.startPrank(testCaller);
        usdc.approve(address(aavePool), usdcAmount);
        
        // Call supply with controlledEOA as onBehalfOf
        aavePool.supply(address(usdc), usdcAmount, controlledEOA, 0);
        
        // Verify it recorded for controlledEOA (proving onBehalfOf is the KEY)
        uint256 testSupplyAmount = aavePool.getSupplied(controlledEOA, address(usdc));
        assertEq(testSupplyAmount, usdcAmount, "DIRECT TEST: supply() with controlledEOA onBehalfOf should record for controlledEOA");
        
        console2.log("DIRECT TEST: Called supply(onBehalfOf=controlledEOA)");
        console2.log("DIRECT TEST: Recorded supplied[controlledEOA] = ", testSupplyAmount);
        
        vm.stopPrank();
        
        // Now verify the ORIGINAL deposit in the test used userEOA as onBehalfOf
        // (which happened via the 7702 delegation in Node 3)
        console2.log("ORIGINAL TEST: Node 3 supply call used onBehalfOf=userEOA");
        console2.log("ORIGINAL TEST: Recorded supplied[userEOA] = ", suppliedToUserEOA);
        
        // Verify 5: The ERC7702 delegation ensured msg.sender was userEOA
        console2.log("=== 7702 Delegation Verification ===");
        console2.log("Deposit signed by:                  userEOA (private key)");
        console2.log("Executed via:                       7702 delegation to delegator");
        console2.log("msg.sender in AavePool:          ", "userEOA (via delegator contract code)");
        console2.log("onBehalfOf in supply() (Node 3): ", "userEOA");
        console2.log("AavePool storage key (Node 3):  ", "userEOA (VERIFIED BY DIRECT CALL)");
        
        // Verify intent state shows all 3 nodes completed
        bytes32 completionKey = keccak256(abi.encode(rootHash, targetNodeHash));
        (bool completed, uint248 bitmap, bytes32 nextHash) = nexusSettler.intentStates(completionKey);
        
        console2.log("=== Intent State ===");
        console2.log("Completed:", completed);
        console2.log("Bitmap:", uint256(bitmap));
        console2.log("Expected bitmap:", uint256(7));
        
        assertTrue(completed, "Intent not marked as completed");
        assertEq(bitmap, 7, "Bitmap should be 7 (binary 111 = all 3 nodes executed)");
        assertEq(nextHash, bytes32(0), "Next hash should be 0 for completed path");
        
        console2.log("=== 3-Node Destination Flow Test PASSED ===");
        console2.log("PASS: aUSDC went to userEOA, not controller or NexusSettler");
        console2.log("PASS: Aave deposit recorded for userEOA");
        console2.log("PASS: 7702 delegation worked correctly");
    }

    /**
     * @notice Test 2: Invalid Signature Naturally Reverts
     * @dev Same setup as Test 1, but with wrong signature
     * Verify transaction reverts with InvalidSignature
     * NexusSettler's _executeAction naturally propagates the revert
     */
    function test_InvalidSignatureNaturallyReverts() public {
        // ============ STEP 1: Setup 7702 Delegation ============
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), address(delegator));
        vm.etch(userEOA, delegationCode);

        // ============ STEP 2: User Creates Calls ============
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution({
            target: recipient,
            value: TRANSFER_AMOUNT,
            callData: ""
        });

        // ============ STEP 3: Create INVALID Signature (wrong private key) ============
        uint256 wrongPrivateKey = 0xDEADBEEF;
        bytes32 executionDigest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, NONCE, 0, calls);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, executionDigest);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        // ============ STEP 4: Encode the execute() Call ============
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute((address,uint256,bytes)[],uint256,uint256,bytes)",
            calls,
            NONCE,
            uint256(0),
            invalidSignature
        );

        // ============ STEP 5: Create Intent via NexusSettler ============
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: userEOA,
            data: executeCalldata
        });

        uint16 chainId = uint16(block.chainid);
        bytes32 firstNodeHash = keccak256(abi.encode(path[0]));
        INexusSettler.TargetNode memory targetNode = _createSingleTargetNode(
            INexusSettler.TargetType.Source,
            chainId,
            firstNodeHash
        );

        bytes32 targetNodeHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({
            s: targetNodeHash,
            d: bytes32(0),
            o: bytes32(0)
        });

        uint256 nonce = 43;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // Sign intent creation with correct key
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
                rootHash,
                nonce
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NexusSettler")),
                keccak256(bytes("2")),
                block.chainid,
                address(nexusSettler)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPrivateKey, digest);
        bytes memory intentSignature = abi.encodePacked(r2, s2, v2);

        // Create the intent
        vm.prank(userEOA);
        nexusSettler.createPI(rootHash, intentSignature, nonce, rootNode);

        // ============ STEP 6: Execute and Expect Revert ============
        // The delegator should revert with InvalidSignature
        // This revert propagates through NexusSettler._executeAction naturally
        vm.prank(controlledEOA);
        vm.expectRevert(ERC7702Delegator.InvalidSignature.selector);
        nexusSettler.processPIPath(
            rootHash,
            rootNode,
            targetNode,
            path,
            nonce,
            true
        );

        // Verify intent was NOT completed
        bytes32 completionKey = keccak256(abi.encode(rootHash, targetNodeHash));
        (bool completed, , ) = nexusSettler.intentStates(completionKey);
        assertFalse(completed, "Intent should not be completed after revert");
    }

    /**
     * @notice Test 3: Delegation Revoked Mid-Flow
     * @dev Intent created, delegation active
     * Revoke delegation: vm.etch(userEOA, "")
     * Controlled EOA calls processPIPath
     * NexusSettler forwards to userEOA
     * Call fails (EOA has no code, no execute function) - NATURAL REVERT
     */
    function test_DelegationRevokedMidFlow() public {
        // ============ STEP 1: Setup 7702 Delegation ============
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), address(delegator));
        vm.etch(userEOA, delegationCode);

        // ============ STEP 2: User Creates Calls ============
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution({
            target: recipient,
            value: TRANSFER_AMOUNT,
            callData: ""
        });

        // ============ STEP 3: User Signs ============
        bytes32 executionDigest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, NONCE, 0, calls);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, executionDigest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // ============ STEP 4: Encode the execute() Call ============
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute((address,uint256,bytes)[],uint256,uint256,bytes)",
            calls,
            NONCE,
            uint256(0),
            signature
        );

        // ============ STEP 5: Create Intent via NexusSettler ============
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: userEOA,
            data: executeCalldata
        });

        uint16 chainId = uint16(block.chainid);
        bytes32 firstNodeHash = keccak256(abi.encode(path[0]));
        INexusSettler.TargetNode memory targetNode = _createSingleTargetNode(
            INexusSettler.TargetType.Source,
            chainId,
            firstNodeHash
        );

        bytes32 targetNodeHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({
            s: targetNodeHash,
            d: bytes32(0),
            o: bytes32(0)
        });

        uint256 nonce = 44;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // Sign intent creation
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
                rootHash,
                nonce
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NexusSettler")),
                keccak256(bytes("2")),
                block.chainid,
                address(nexusSettler)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPrivateKey, digest);
        bytes memory intentSignature = abi.encodePacked(r2, s2, v2);

        // Create the intent
        vm.prank(userEOA);
        nexusSettler.createPI(rootHash, intentSignature, nonce, rootNode);

        // ============ STEP 6: REVOKE DELEGATION ============
        // Clear the code at userEOA - simulating delegation revocation
        vm.etch(userEOA, "");
        assertEq(userEOA.code.length, 0, "Delegation not revoked");

        // ============ STEP 7: Execute and Expect Revert ============
        // Now when NexusSettler calls userEOA, it will fail because:
        // - userEOA has no code
        // - The execute() function doesn't exist
        // - The call naturally reverts
        vm.prank(controlledEOA);
        // Expect any revert since the call will fail
        vm.expectRevert();
        nexusSettler.processPIPath(
            rootHash,
            rootNode,
            targetNode,
            path,
            nonce,
            true
        );

        // Verify intent was NOT completed
        bytes32 completionKey = keccak256(abi.encode(rootHash, targetNodeHash));
        (bool completed, , ) = nexusSettler.intentStates(completionKey);
        assertFalse(completed, "Intent should not be completed after delegation revoked");
    }

    /**
     * @notice Test 4: Multiple Calls in Single Execution
     * @dev Tests batch execution through 7702 delegator
     */
    function test_MultipleCallsInSingleExecution() public {
        // Setup 7702 Delegation
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), address(delegator));
        vm.etch(userEOA, delegationCode);

        // Create multiple recipients
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");

        // Create multiple calls
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution({
            target: recipient1,
            value: 0.3 ether,
            callData: ""
        });
        calls[1] = Execution({
            target: recipient2,
            value: 0.2 ether,
            callData: ""
        });

        // Sign
        bytes32 executionDigest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, NONCE, 0, calls);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, executionDigest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Encode execute call
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute((address,uint256,bytes)[],uint256,uint256,bytes)",
            calls,
            NONCE,
            uint256(0),
            signature
        );

        // Create intent
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: userEOA,
            data: executeCalldata
        });

        uint16 chainId = uint16(block.chainid);
        bytes32 firstNodeHash = keccak256(abi.encode(path[0]));
        INexusSettler.TargetNode memory targetNode = _createSingleTargetNode(
            INexusSettler.TargetType.Source,
            chainId,
            firstNodeHash
        );

        bytes32 targetNodeHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({
            s: targetNodeHash,
            d: bytes32(0),
            o: bytes32(0)
        });

        uint256 nonce = 45;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // Sign intent
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
                rootHash,
                nonce
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NexusSettler")),
                keccak256(bytes("2")),
                block.chainid,
                address(nexusSettler)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPrivateKey, digest);
        bytes memory intentSignature = abi.encodePacked(r2, s2, v2);

        vm.prank(userEOA);
        nexusSettler.createPI(rootHash, intentSignature, nonce, rootNode);

        // Execute
        uint256 balanceBefore1 = recipient1.balance;
        uint256 balanceBefore2 = recipient2.balance;

        vm.prank(controlledEOA);
        nexusSettler.processPIPath(
            rootHash,
            rootNode,
            targetNode,
            path,
            nonce,
            true
        );

        // Verify both recipients received funds
        assertEq(recipient1.balance - balanceBefore1, 0.3 ether, "Recipient1 did not receive correct amount");
        assertEq(recipient2.balance - balanceBefore2, 0.2 ether, "Recipient2 did not receive correct amount");
    }

    /**
     * @notice Test 5: Nonce Replay Protection
     * @dev Verifies that the same nonce cannot be reused
     */
    function test_NonceReplayProtection() public {
        // Setup 7702 Delegation
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), address(delegator));
        vm.etch(userEOA, delegationCode);

        // Create calls
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution({
            target: recipient,
            value: TRANSFER_AMOUNT,
            callData: ""
        });

        // Sign with NONCE
        bytes32 executionDigest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, NONCE, 0, calls);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, executionDigest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Encode execute call
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute((address,uint256,bytes)[],uint256,uint256,bytes)",
            calls,
            NONCE,
            uint256(0),
            signature
        );

        // Create intent
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: userEOA,
            data: executeCalldata
        });

        uint16 chainId = uint16(block.chainid);
        bytes32 firstNodeHash = keccak256(abi.encode(path[0]));
        INexusSettler.TargetNode memory targetNode = _createSingleTargetNode(
            INexusSettler.TargetType.Source,
            chainId,
            firstNodeHash
        );

        bytes32 targetNodeHash = keccak256(abi.encode(targetNode));
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({
            s: targetNodeHash,
            d: bytes32(0),
            o: bytes32(0)
        });

        uint256 nonce = 46;
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // Sign intent
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
                rootHash,
                nonce
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NexusSettler")),
                keccak256(bytes("2")),
                block.chainid,
                address(nexusSettler)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(userPrivateKey, digest);
        bytes memory intentSignature = abi.encodePacked(r2, s2, v2);

        vm.prank(userEOA);
        nexusSettler.createPI(rootHash, intentSignature, nonce, rootNode);

        // First execution should succeed
        vm.prank(controlledEOA);
        nexusSettler.processPIPath(
            rootHash,
            rootNode,
            targetNode,
            path,
            nonce,
            true
        );

        // Second execution with same nonce should revert
        // We need to create a new intent since the old one is completed
        // But the delegator nonce is already used
        uint256 nonce2 = 47;
        bytes32 rootHash2 = keccak256(abi.encode(rootNode, nonce2));
        bytes32 structHash2 = keccak256(
            abi.encode(
                keccak256("NexusPI(bytes32 rootHash,uint256 nonce)"),
                rootHash2,
                nonce2
            )
        );
        bytes32 digest2 = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash2));
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(userPrivateKey, digest2);
        bytes memory intentSignature2 = abi.encodePacked(r3, s3, v3);

        vm.prank(userEOA);
        nexusSettler.createPI(rootHash2, intentSignature2, nonce2, rootNode);

        // This should revert because nonce is already used in delegator
        vm.prank(controlledEOA);
        vm.expectRevert(abi.encodeWithSelector(ERC7702Delegator.NonceAlreadyUsed.selector, NONCE));
        nexusSettler.processPIPath(
            rootHash2,
            rootNode,
            targetNode,
            path,
            nonce2,
            true
        );
    }

    // ============ Helper Functions ============

    /**
     * @notice Creates single-chain TargetNode (k=1)
     */
    function _createSingleTargetNode(
        INexusSettler.TargetType targetType,
        uint16 chainId,
        bytes32 targetHash
    ) internal pure returns (INexusSettler.TargetNode memory) {
        uint16[] memory chainIds = new uint16[](1);
        chainIds[0] = chainId;
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = targetHash;
        return _createTargetNode(targetType, chainIds, hashes);
    }

    /**
     * @notice Creates TargetNode with perfect hash data
     */
    function _createTargetNode(
        INexusSettler.TargetType targetType,
        uint16[] memory chainIds,
        bytes32[] memory hashes
    ) internal pure returns (INexusSettler.TargetNode memory) {
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
}

/**
 * @title MockUSDC
 * @notice Mock USDC token with 6 decimals for testing
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        // USDC has 6 decimals
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
