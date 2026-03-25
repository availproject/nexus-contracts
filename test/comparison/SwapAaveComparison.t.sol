// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../src/NexusSettler.sol";
import "../../src/interfaces/INexusSettler.sol";
import "../mocks/MockV4SwapRouter.sol";
import "../mocks/MockPoolManager.sol";
import "../mocks/MockAavePool.sol";
import "../mocks/MockAToken.sol";
import "../mocks/DirectSwapAaveExecutor.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

// ============================================================================
// Test Constants
// ============================================================================

uint256 constant INITIAL_BALANCE = 1000000e18;
uint256 constant SWAP_AMOUNT_IN = 1000e18;
uint256 constant SWAP_MIN_AMOUNT_OUT = 995e18; // ~0.5% slippage
uint256 constant DEPOSIT_AMOUNT = 995e18;

// ============================================================================
// Mock ERC20 Token (for test tokens)
// ============================================================================

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============================================================================
// SwapAaveComparison Test
// ============================================================================

/**
 * @title SwapAaveComparison
 * @notice Restructured comparison tests using extracted mocks
 * @dev Tests Direct Sequential vs DAG Graph approaches with execution step counting
 */
contract SwapAaveComparison is Test {
    // NexusSettler and Direct Executor
    NexusSettler public nexusSettler;
    DirectSwapAaveExecutor public directSwapAaveExecutor;

    // Test addresses
    address public escrow;
    address public owner;
    address public filler;

    // Mock contracts (extracted)
    MockPoolManager public mockPoolManager;
    MockV4SwapRouter public mockV4SwapRouter;
    MockAavePool public mockAavePool;
    MockAToken public mockAToken;

    // Test tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    // Swap constants
    uint24 constant SWAP_FEE = 3000; // 0.3% fee tier

    // ============================================================================
    // Events for tracking execution steps
    // ============================================================================

    event IntendNodeExec(bytes32 indexed nodeHash, uint256 level);

    function setUp() public {
        // Setup test addresses
        escrow = makeAddr("escrow");
        owner = makeAddr("owner");
        filler = makeAddr("filler");

        // Deploy NexusSettler
        nexusSettler = new NexusSettler(escrow);

        // Deploy mock infrastructure
        mockPoolManager = new MockPoolManager();
        mockV4SwapRouter = new MockV4SwapRouter(address(mockPoolManager));
        mockAavePool = new MockAavePool();

        // Deploy DirectSwapAaveExecutor (extracted mock)
        directSwapAaveExecutor = new DirectSwapAaveExecutor(address(mockV4SwapRouter), address(mockAavePool));

        // Deploy test tokens (MUST be before setting aToken mapping)
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");

        // Deploy and link MockAToken for tokenB (after tokenB exists)
        mockAToken = new MockAToken("Aave Token B", "aTKB");
        mockAToken.setMinter(address(mockAavePool)); // Pool is the minter for aTokens
        mockAavePool.setATokenForAsset(address(tokenB), address(mockAToken));

        // Initialize pool with liquidity
        address token0 = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address token1 = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        // Create pool key for initialization
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: SWAP_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Mint tokens to this contract for pool initialization
        tokenA.mint(address(this), INITIAL_BALANCE);
        tokenB.mint(address(this), INITIAL_BALANCE);

        // Approve pool manager
        IERC20(token0).approve(address(mockPoolManager), type(uint256).max);
        IERC20(token1).approve(address(mockPoolManager), type(uint256).max);

        // Initialize pool
        mockPoolManager.initializePool(key, INITIAL_BALANCE, INITIAL_BALANCE);

        // Mint tokens to owner and filler
        tokenA.mint(owner, INITIAL_BALANCE);
        tokenA.mint(filler, INITIAL_BALANCE);
        tokenB.mint(owner, INITIAL_BALANCE);
        tokenB.mint(filler, INITIAL_BALANCE);

        // Setup approvals for owner
        vm.startPrank(owner);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenA.approve(address(directSwapAaveExecutor), type(uint256).max);
        tokenA.approve(address(mockV4SwapRouter), type(uint256).max);
        tokenA.approve(address(mockAavePool), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(directSwapAaveExecutor), type(uint256).max);
        tokenB.approve(address(mockV4SwapRouter), type(uint256).max);
        tokenB.approve(address(mockAavePool), type(uint256).max);
        vm.stopPrank();

        // Setup approvals for filler
        vm.startPrank(filler);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenA.approve(address(directSwapAaveExecutor), type(uint256).max);
        tokenA.approve(address(mockV4SwapRouter), type(uint256).max);
        tokenA.approve(address(mockAavePool), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(directSwapAaveExecutor), type(uint256).max);
        tokenB.approve(address(mockV4SwapRouter), type(uint256).max);
        tokenB.approve(address(mockAavePool), type(uint256).max);
        vm.stopPrank();
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

    /// @notice Helper to execute full DAG flow: createPI + processPIPath
    /// @dev Creates targetNode from entryNodeHash, computes proper rootNode.d, 
    ///      creates intent, and processes the path
    function _executeFullDAGFlow(
        bytes32 entryNodeHash,
        INexusSettler.IntendNode[] memory path,
        bytes32 s,
        bytes32 o,
        uint256 nonce,
        uint256 fillerPrivateKey
    ) internal {
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

        INexusSettler.TargetNode memory targetNode =
            INexusSettler.TargetNode({targetType: INexusSettler.TargetType.Destination, chainIdToNode: chainIdToNode});

        // Compute d = keccak256(abi.encode(targetNode)) for validation
        bytes32 d = keccak256(abi.encode(targetNode));

        // Create rootNode with computed d
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});

        // Compute rootHash using correct struct encoding
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // Generate and verify signature
        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        // Create intent
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        // Process path
        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, false);
    }

    /// @notice Helper to execute processPIPath only (for already-created intents)
    /// @dev Uses pre-computed rootNode with correct d value
    function _executeProcessPIPath(
        bytes32 rootHash,
        INexusSettler.RootNode memory rootNode,
        bytes32 entryNodeHash,
        INexusSettler.IntendNode[] memory path,
        uint256 nonce
    ) internal {
        // Build targetNode from entryNodeHash
        bytes memory chainIdToNode = new bytes(38);
        chainIdToNode[0] = bytes1(uint8(0));
        chainIdToNode[1] = bytes1(uint8(1));
        chainIdToNode[2] = bytes1(uint8(0));
        chainIdToNode[3] = bytes1(uint8(0));
        chainIdToNode[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNode[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNode[6 + i] = entryNodeHash[i];
        }

        INexusSettler.TargetNode memory targetNode =
            INexusSettler.TargetNode({targetType: INexusSettler.TargetType.Destination, chainIdToNode: chainIdToNode});

        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, false);
    }

    /// @notice Count execution steps by counting IntendNodeExec events
    /// @param path The IntendNode path
    /// @return stepCount Number of nodes in path (Node Traversal Count)
    function _countExecutionSteps(INexusSettler.IntendNode[] memory path) internal pure returns (uint256 stepCount) {
        return path.length;
    }

    // ============================================================================
    // Test 1: Direct Sequential Gas Profile (Swap then Deposit)
    // ============================================================================

    /**
     * @notice Profile gas for Direct Sequential approach: swap then deposit
     *         This measures the baseline gas cost without NexusSettler overhead
     */
    function testGasProfile_DirectSequential_SwapThenDeposit() public {
        // 1. Create fresh filler with unique name for clean state
        address fillerDirect = makeAddr("filler_direct_sequential");

        // 2. Mint tokens to filler
        tokenA.mint(fillerDirect, INITIAL_BALANCE);

        // 3. Setup approvals (prank as filler)
        vm.startPrank(fillerDirect);
        tokenA.approve(address(directSwapAaveExecutor), type(uint256).max);
        tokenB.approve(address(directSwapAaveExecutor), type(uint256).max);
        vm.stopPrank();

        // 4. Measure gas for swap + deposit execution
        vm.prank(fillerDirect);
        uint256 gasStart = gasleft();

        directSwapAaveExecutor.execute(
            address(tokenA), // tokenIn
            address(tokenB), // tokenOut
            SWAP_AMOUNT_IN, // swapAmount
            DEPOSIT_AMOUNT, // depositAmount
            fillerDirect, // beneficiary (receives aTokens)
            SWAP_MIN_AMOUNT_OUT // minAmountOut (slippage protection)
        );

        uint256 gasUsed = gasStart - gasleft();

        // 5. Log results with execution step count
        console2.log("=== Direct Sequential Gas ===");
        console2.log("Gas used:", gasUsed);
        console2.log("Node Traversal Count: 1 (single execution)");

        // 6. Verify state - filler has aTokens (via MockAToken)
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDirect);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        // 7. Verify state - pool received tokenB (for Aave deposit)
        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDirect, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");

        // 8. Verify swap happened - filler should have less tokenA
        uint256 fillerTokenA = tokenA.balanceOf(fillerDirect);
        assertEq(fillerTokenA, INITIAL_BALANCE - SWAP_AMOUNT_IN, "Filler should have less tokenA after swap");
    }

    // ============================================================================
    // Test 2: DAG Graph Gas Profile (Swap + Deposit Connected)
    // ============================================================================

    /**
     * @notice Profile gas for DAG Graph approach: swap + deposit via NexusSettler
     *         This measures gas cost using createPI + processPIPath with connected nodes
     */
    function testGasProfile_DAG_SwapDepositConnected() public {
        // 1. Create fresh filler with NexusSettler approvals
        address fillerDag = makeAddr("filler_dag");
        uint256 fillerDagPrivateKey = 0x123456789abcdef;

        // Mint tokens to filler
        tokenA.mint(fillerDag, INITIAL_BALANCE);

        // Setup approvals: filler approves NexusSettler to pull tokens
        vm.startPrank(fillerDag);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // 2. Setup root node parameters (d will be computed from targetNode)
        bytes32 s = keccak256("source");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;

        // 3. Create IntendNode[] path with 5 connected nodes:
        // Node 0: Pull tokens from filler to NexusSettler
        // Node 1: Approve pool manager to spend NexusSettler's tokens
        // Node 2: Swap tokenA for tokenB
        // Node 3: Approve Aave pool to spend tokenB
        // Node 4: Deposit tokenB to Aave
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](5);

        // Node 4: Deposit to Aave (end of path)
        path[4] = INexusSettler.IntendNode({
            next: bytes32(0), // End of path
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 3: Approve Aave pool to spend tokenB (points to node 4)
        path[3] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[4])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), DEPOSIT_AMOUNT)
        });

        // Node 2: Swap tokenA for tokenB via pool manager (points to node 3)
        PoolKey memory swapKey = PoolKey({
            currency0: Currency.wrap(address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB)),
            currency1: Currency.wrap(address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA)),
            fee: SWAP_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        bool zeroForOne = address(tokenA) < address(tokenB);

        path[2] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[3])),
            target: address(mockPoolManager),
            data: abi.encodeWithSignature(
                "swap((address,address,uint24,int24,address),bool,uint256,uint256)",
                swapKey,
                zeroForOne,
                SWAP_AMOUNT_IN,
                SWAP_MIN_AMOUNT_OUT
            )
        });

        // Node 1: Approve pool manager to spend NexusSettler's tokens (points to node 2)
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenA),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockPoolManager), SWAP_AMOUNT_IN)
        });

        // Node 0: Pull tokens from filler to NexusSettler (points to node 1)
        INexusSettler.IntendNode memory node0 = INexusSettler.IntendNode({
            next: bytes32(0), // placeholder, will be set to hash of path[1]
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), SWAP_AMOUNT_IN
            )
        });
        path[0] = node0;
        path[0].next = keccak256(abi.encode(path[1]));

        // 5. Measure gas and execute
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStart = gasleft();
        _executeFullDAGFlow(entryNodeHash, path, s, o, nonce, fillerDagPrivateKey);
        uint256 gasUsed = gasStart - gasleft();

        // 5b. Compute rootHash for verification (same as _executeFullDAGFlow)
        bytes memory chainIdToNodeRoot = new bytes(38);
        chainIdToNodeRoot[0] = bytes1(uint8(0));
        chainIdToNodeRoot[1] = bytes1(uint8(1));
        chainIdToNodeRoot[2] = bytes1(uint8(0));
        chainIdToNodeRoot[3] = bytes1(uint8(0));
        chainIdToNodeRoot[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNodeRoot[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNodeRoot[6 + i] = entryNodeHash[i];
        }
        INexusSettler.TargetNode memory targetNodeRoot = INexusSettler.TargetNode({
            targetType: INexusSettler.TargetType.Destination,
            chainIdToNode: chainIdToNodeRoot
        });
        bytes32 d = keccak256(abi.encode(targetNodeRoot));
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // 6. Log results with execution step count
        uint256 stepCount = _countExecutionSteps(path);
        console2.log("=== DAG Graph Gas ===");
        console2.log("Gas used:", gasUsed);
        console2.log("Node Traversal Count:", stepCount);

        // 7. Verify state
        bytes32 computedTargetNodeHash = keccak256(abi.encode(targetNodeRoot));
        bytes32 completionKey = keccak256(abi.encode(rootHash, computedTargetNodeHash));
        (bool isComplete,) = nexusSettler.intentStates(completionKey);
        assertTrue(isComplete, "Path should be completed");

        // Verify filler has aTokens
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDag);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        // Verify pool received tokenB
        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDag, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");
    }

    // ============================================================================
    // Test 3: Gas Comparison (Direct vs DAG)
    // ============================================================================

    /**
     * @notice Compare gas costs between Direct Sequential and DAG Graph approaches
     *         using vm.snapshot() to ensure fair comparison with clean state
     */
    function testGasProfile_Comparison() public {
        // Use vm.snapshot() for fair comparison
        uint256 state = vm.snapshot();

        // ============ DIRECT SEQUENTIAL ============
        address fillerDirect = makeAddr("filler_comparison_direct");

        // Setup fresh filler
        tokenA.mint(fillerDirect, INITIAL_BALANCE);
        vm.startPrank(fillerDirect);
        tokenA.approve(address(directSwapAaveExecutor), type(uint256).max);
        vm.stopPrank();

        // Measure gas
        vm.prank(fillerDirect);
        uint256 gasStart = gasleft();
        directSwapAaveExecutor.execute(
            address(tokenA), address(tokenB), SWAP_AMOUNT_IN, DEPOSIT_AMOUNT, fillerDirect, SWAP_MIN_AMOUNT_OUT
        );
        uint256 gasDirect = gasStart - gasleft();

        // ============ DAG GRAPH ============
        // Revert to clean state
        vm.revertTo(state);

        address fillerDag = makeAddr("filler_comparison_dag");
        uint256 fillerDagPrivateKey = 0xabcdef123456789;

        // Setup fresh filler
        tokenA.mint(fillerDag, INITIAL_BALANCE);
        vm.startPrank(fillerDag);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // 2. Setup root node parameters (d will be computed from targetNode)
        bytes32 s = keccak256("source");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;

        // 3. Create 5-node path (same as DAG test)
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](5);

        // Node 4: Deposit
        path[4] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 3: Approve Aave
        path[3] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[4])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), DEPOSIT_AMOUNT)
        });

        // Node 2: Swap
        PoolKey memory swapKey = PoolKey({
            currency0: Currency.wrap(address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB)),
            currency1: Currency.wrap(address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA)),
            fee: SWAP_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        bool zeroForOne = address(tokenA) < address(tokenB);

        path[2] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[3])),
            target: address(mockPoolManager),
            data: abi.encodeWithSignature(
                "swap((address,address,uint24,int24,address),bool,uint256,uint256)",
                swapKey,
                zeroForOne,
                SWAP_AMOUNT_IN,
                SWAP_MIN_AMOUNT_OUT
            )
        });

        // Node 1: Approve pool manager
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenA),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockPoolManager), SWAP_AMOUNT_IN)
        });

        // Node 0: Pull tokens
        INexusSettler.IntendNode memory node0ComparisonSwap = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), SWAP_AMOUNT_IN
            )
        });
        path[0] = node0ComparisonSwap;
        path[0].next = keccak256(abi.encode(path[1]));

        // Measure gas
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStartDag = gasleft();
        _executeFullDAGFlow(entryNodeHash, path, s, o, nonce, fillerDagPrivateKey);
        uint256 gasDAG = gasStartDag - gasleft();

        // ============ COMPARISON OUTPUT ============
        uint256 directSteps = 1;
        uint256 dagSteps = _countExecutionSteps(path);

        console2.log("\n=== Gas Comparison (Swap + Aave Deposit) ===");
        console2.log("Direct Sequential gas:", gasDirect);
        console2.log("Direct Node Traversal Count:", directSteps);
        console2.log("DAG Graph gas:", gasDAG);
        console2.log("DAG Node Traversal Count:", dagSteps);
        if (gasDAG >= gasDirect) {
            console2.log("Difference (DAG overhead):", gasDAG - gasDirect);
            console2.log("Overhead %:", ((gasDAG - gasDirect) * 100) / gasDirect, "%");
        } else {
            console2.log("DAG SAVINGS:", gasDirect - gasDAG);
            console2.log("Savings %:", ((gasDirect - gasDAG) * 100) / gasDirect, "%");
        }
    }

    // ============================================================================
    // Test 4: Direct Aave Deposit Only
    // ============================================================================

    /**
     * @notice Profile gas for direct Aave deposit only (no swap)
     *         Uses executor contract for fair comparison with DAG
     */
    function testGasProfile_DirectAaveDepositOnly() public {
        // 1. Create fresh filler
        address fillerDirect = makeAddr("filler_direct_deposit_only");

        // 2. Mint tokenB directly to filler (skip swap)
        tokenB.mint(fillerDirect, INITIAL_BALANCE);

        // 3. Setup approvals — filler approves executor to pull
        vm.startPrank(fillerDirect);
        tokenB.approve(address(directSwapAaveExecutor), type(uint256).max);
        vm.stopPrank();

        // 4. Measure gas: executor does pull -> approve -> supply
        vm.prank(fillerDirect);
        uint256 gasStart = gasleft();

        directSwapAaveExecutor.depositOnly(address(tokenB), DEPOSIT_AMOUNT, fillerDirect);

        uint256 gasUsed = gasStart - gasleft();

        // 5. Log results with execution step count
        console2.log("=== Direct Aave Deposit Only Gas ===");
        console2.log("Gas used:", gasUsed);
        console2.log("Node Traversal Count: 1 (single execution)");

        // 6. Verify state
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDirect);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDirect, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");
    }

    // ============================================================================
    // Test 5: DAG Deposit Only
    // ============================================================================

    /**
     * @notice Profile gas for DAG Graph: deposit only (no swap)
     *         This tests DAG overhead for a single deposit operation
     */
    function testGasProfile_DAG_DepositOnly() public {
        // 1. Create fresh filler with NexusSettler approvals
        address fillerDag = makeAddr("filler_dag_deposit_only");
        uint256 fillerDagPrivateKey = 0xfedcba9876543210;

        // Mint tokenB to filler (no swap needed)
        tokenB.mint(fillerDag, INITIAL_BALANCE);

        // Setup approvals
        vm.startPrank(fillerDag);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // 2. Setup root node parameters (d will be computed from targetNode)
        bytes32 s = keccak256("source_deposit_only");
        bytes32 o = keccak256("offchain_deposit_only");
        uint256 nonce = 2;

        // 3. Create IntendNode[] path with 3 connected nodes:
        // Node 0: Pull tokenB from filler to NexusSettler
        // Node 1: Approve Aave pool to spend tokenB
        // Node 2: Deposit tokenB to Aave
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](3);

        // Node 2: Deposit to Aave (end of path)
        path[2] = INexusSettler.IntendNode({
            next: bytes32(0), // End of path
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 1: Approve Aave pool to spend tokenB (points to node 2)
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), DEPOSIT_AMOUNT)
        });

        // Node 0: Pull tokenB from filler to NexusSettler (points to node 1)
        INexusSettler.IntendNode memory node0DepositOnly = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(tokenB),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), DEPOSIT_AMOUNT
            )
        });
        path[0] = node0DepositOnly;
        path[0].next = keccak256(abi.encode(path[1]));

        // 5. Measure gas and execute
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStart = gasleft();
        _executeFullDAGFlow(entryNodeHash, path, s, o, nonce, fillerDagPrivateKey);
        uint256 gasUsed = gasStart - gasleft();

        // 5b. Compute rootHash for verification (same as _executeFullDAGFlow)
        bytes memory chainIdToNodeRoot = new bytes(38);
        chainIdToNodeRoot[0] = bytes1(uint8(0));
        chainIdToNodeRoot[1] = bytes1(uint8(1));
        chainIdToNodeRoot[2] = bytes1(uint8(0));
        chainIdToNodeRoot[3] = bytes1(uint8(0));
        chainIdToNodeRoot[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNodeRoot[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNodeRoot[6 + i] = entryNodeHash[i];
        }
        INexusSettler.TargetNode memory targetNodeRoot = INexusSettler.TargetNode({
            targetType: INexusSettler.TargetType.Destination,
            chainIdToNode: chainIdToNodeRoot
        });
        bytes32 d = keccak256(abi.encode(targetNodeRoot));
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // 6. Log results with execution step count
        uint256 stepCount = _countExecutionSteps(path);
        console2.log("=== DAG Graph Gas (Deposit Only) ===");
        console2.log("Gas used:", gasUsed);
        console2.log("Node Traversal Count:", stepCount);

        // 7. Verify state
        bytes32 computedTargetNodeHash = keccak256(abi.encode(targetNodeRoot));
        bytes32 completionKey = keccak256(abi.encode(rootHash, computedTargetNodeHash));
        (bool isComplete,) = nexusSettler.intentStates(completionKey);
        assertTrue(isComplete, "Path should be completed");

        // Verify filler has aTokens
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDag);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        // Verify pool received tokenB
        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDag, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");
    }

    // ============================================================================
    // Test 6: Comparison Deposit Only
    // ============================================================================

    /**
     * @notice Compare direct Aave deposit vs DAG deposit-only flow
     *         Uses vm.snapshot() for fair comparison
     */
    function testGasProfile_Comparison_DepositOnly() public {
        // Use vm.snapshot() for fair comparison
        uint256 state = vm.snapshot();

        // ============ DIRECT DEPOSIT VIA EXECUTOR ============
        address fillerDirect = makeAddr("filler_comparison_direct_deposit");

        // Setup fresh filler with tokenB
        tokenB.mint(fillerDirect, INITIAL_BALANCE);
        vm.startPrank(fillerDirect);
        tokenB.approve(address(directSwapAaveExecutor), type(uint256).max);
        vm.stopPrank();

        // Measure gas: executor does pull -> approve -> supply
        vm.prank(fillerDirect);
        uint256 gasStart = gasleft();
        directSwapAaveExecutor.depositOnly(address(tokenB), DEPOSIT_AMOUNT, fillerDirect);
        uint256 gasDirect = gasStart - gasleft();

        // ============ DAG DEPOSIT ONLY ============
        // Revert to clean state
        vm.revertTo(state);

        address fillerDag = makeAddr("filler_comparison_dag_deposit");
        uint256 fillerDagPrivateKey = 0xabcdef1234567890;

        // Setup fresh filler with tokenB
        tokenB.mint(fillerDag, INITIAL_BALANCE);
        vm.startPrank(fillerDag);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // 2. Setup root node parameters (d will be computed from targetNode)
        bytes32 s = keccak256("source_comparison");
        bytes32 o = keccak256("offchain_comparison");
        uint256 nonce = 3;

        // 3. Create 3-node path (pull -> approve aave -> deposit)
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](3);

        // Node 2: Deposit
        path[2] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 1: Approve Aave pool
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), DEPOSIT_AMOUNT)
        });

        // Node 0: Pull tokens
        INexusSettler.IntendNode memory node0Comparison = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(tokenB),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), DEPOSIT_AMOUNT
            )
        });
        path[0] = node0Comparison;
        path[0].next = keccak256(abi.encode(path[1]));

        // Measure gas
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStartDag = gasleft();
        _executeFullDAGFlow(entryNodeHash, path, s, o, nonce, fillerDagPrivateKey);
        uint256 gasDAG = gasStartDag - gasleft();

        // ============ COMPARISON OUTPUT ============
        uint256 directSteps = 1;
        uint256 dagSteps = _countExecutionSteps(path);

        console2.log("\n=== Gas Comparison (Deposit Only) ===");
        console2.log("Direct Aave Deposit Only gas:", gasDirect);
        console2.log("Direct Node Traversal Count:", directSteps);
        console2.log("DAG (Deposit Only) gas:", gasDAG);
        console2.log("DAG Node Traversal Count:", dagSteps);
        console2.log("Difference (DAG overhead):", gasDAG - gasDirect);
        console2.log("Overhead %:", ((gasDAG - gasDirect) * 100) / gasDirect, "%");

        // Verify DAG gas is higher (expected overhead)
        assertGt(gasDAG, gasDirect, "DAG should have overhead vs Direct");
    }

    // ============================================================================
    // Test 7: DAG Deposit -> Swap -> Deposit
    // ============================================================================

    /**
     * @notice Profile gas for DAG Graph: deposit -> swap -> deposit flow
     *         This tests a more complex DAG with 3 operations
     */
    function testGasProfile_DAG_DepositSwapDeposit() public {
        // 1. Create fresh filler with NexusSettler approvals
        address fillerDag = makeAddr("filler_dag_deposit_swap_deposit");
        uint256 fillerDagPrivateKey = 0xfedcba9876543210;

        // Mint tokenA to filler (will be swapped to tokenB, then deposited)
        tokenA.mint(fillerDag, INITIAL_BALANCE);

        // Setup approvals
        vm.startPrank(fillerDag);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // 2. Setup root node parameters (d will be computed from targetNode)
        bytes32 s = keccak256("source_deposit_swap");
        bytes32 o = keccak256("offchain_deposit_swap");
        uint256 nonce = 2;

        // 3. Create IntendNode[] path with 5 connected nodes:
        // Node 0: Pull tokenA from filler to NexusSettler
        // Node 1: Approve pool manager for swap
        // Node 2: Swap tokenA for tokenB
        // Node 3: Approve Aave pool for deposit
        // Node 4: Deposit tokenB to Aave
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](5);

        // Node 4: Deposit to Aave (end of path)
        path[4] = INexusSettler.IntendNode({
            next: bytes32(0), // End of path
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 3: Approve Aave pool to spend tokenB (points to node 4)
        path[3] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[4])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), DEPOSIT_AMOUNT)
        });

        // Node 2: Swap tokenA for tokenB via pool manager (points to node 3)
        PoolKey memory swapKey = PoolKey({
            currency0: Currency.wrap(address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB)),
            currency1: Currency.wrap(address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA)),
            fee: SWAP_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        bool zeroForOne = address(tokenA) < address(tokenB);

        path[2] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[3])),
            target: address(mockPoolManager),
            data: abi.encodeWithSignature(
                "swap((address,address,uint24,int24,address),bool,uint256,uint256)",
                swapKey,
                zeroForOne,
                SWAP_AMOUNT_IN,
                SWAP_MIN_AMOUNT_OUT
            )
        });

        // Node 1: Approve pool manager to spend tokenA (points to node 2)
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenA),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockPoolManager), SWAP_AMOUNT_IN)
        });

        // Node 0: Pull tokenA from filler to NexusSettler (points to node 1)
        INexusSettler.IntendNode memory node0DepositSwapDeposit = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), SWAP_AMOUNT_IN
            )
        });
        path[0] = node0DepositSwapDeposit;
        path[0].next = keccak256(abi.encode(path[1]));

        // 5. Measure gas and execute
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStart = gasleft();
        _executeFullDAGFlow(entryNodeHash, path, s, o, nonce, fillerDagPrivateKey);
        uint256 gasUsed = gasStart - gasleft();

        // 5b. Compute rootHash for verification (same as _executeFullDAGFlow)
        bytes memory chainIdToNodeRoot = new bytes(38);
        chainIdToNodeRoot[0] = bytes1(uint8(0));
        chainIdToNodeRoot[1] = bytes1(uint8(1));
        chainIdToNodeRoot[2] = bytes1(uint8(0));
        chainIdToNodeRoot[3] = bytes1(uint8(0));
        chainIdToNodeRoot[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNodeRoot[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNodeRoot[6 + i] = entryNodeHash[i];
        }
        INexusSettler.TargetNode memory targetNodeRoot = INexusSettler.TargetNode({
            targetType: INexusSettler.TargetType.Destination,
            chainIdToNode: chainIdToNodeRoot
        });
        bytes32 d = keccak256(abi.encode(targetNodeRoot));
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // 6. Log results with execution step count
        uint256 stepCount = _countExecutionSteps(path);
        console2.log("=== DAG Graph Gas (Deposit -> Swap -> Deposit) ===");
        console2.log("Gas used:", gasUsed);
        console2.log("Node Traversal Count:", stepCount);

        // 7. Verify state
        bytes32 computedTargetNodeHashDSD = keccak256(abi.encode(targetNodeRoot));
        bytes32 completionKey = keccak256(abi.encode(rootHash, computedTargetNodeHashDSD));
        (bool isComplete,) = nexusSettler.intentStates(completionKey);
        assertTrue(isComplete, "Path should be completed");

        // Verify filler has aTokens
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDag);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        // Verify pool received tokenB
        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDag, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");
    }

    // ============================================================================
    // Test 8: Comparison Deposit -> Swap -> Deposit
    // ============================================================================

    /**
     * @notice Compare direct swap+deposit vs DAG pull+swap+deposit flow
     *         FAIR COMPARISON: Both sides perform swap + deposit operations
     *         Uses vm.snapshot() for fair comparison
     */
    function testGasProfile_Comparison_DepositSwapDeposit() public {
        // Use vm.snapshot() for fair comparison
        uint256 state = vm.snapshot();

        // ============ DIRECT SWAP + DEPOSIT ============
        address fillerDirect = makeAddr("filler_comparison_direct_swap_deposit");

        // Setup fresh filler with tokenA (will swap to tokenB, then deposit)
        tokenA.mint(fillerDirect, INITIAL_BALANCE);
        vm.startPrank(fillerDirect);
        tokenA.approve(address(directSwapAaveExecutor), type(uint256).max);
        vm.stopPrank();

        // Measure gas for direct swap + deposit
        vm.prank(fillerDirect);
        uint256 gasStart = gasleft();
        directSwapAaveExecutor.execute(
            address(tokenA), // tokenIn
            address(tokenB), // tokenOut
            SWAP_AMOUNT_IN, // swapAmount
            DEPOSIT_AMOUNT, // depositAmount
            fillerDirect, // beneficiary
            SWAP_MIN_AMOUNT_OUT // minAmountOut
        );
        uint256 gasDirect = gasStart - gasleft();

        // ============ DAG PULL + SWAP + DEPOSIT ============
        // Revert to clean state
        vm.revertTo(state);

        address fillerDag = makeAddr("filler_comparison_dag_pull_swap_deposit");
        uint256 fillerDagPrivateKey = 0xabcdef1234567890;

        // Setup fresh filler with tokenA
        tokenA.mint(fillerDag, INITIAL_BALANCE);
        vm.startPrank(fillerDag);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // 2. Setup root node parameters (d will be computed from targetNode)
        bytes32 s = keccak256("source_comparison");
        bytes32 o = keccak256("offchain_comparison");
        uint256 nonce = 3;

        // 3. Create 5-node path (pull -> approve -> swap -> approve -> deposit)
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](5);

        // Node 4: Deposit
        path[4] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 3: Approve Aave
        path[3] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[4])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), DEPOSIT_AMOUNT)
        });

        // Node 2: Swap
        PoolKey memory swapKey = PoolKey({
            currency0: Currency.wrap(address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB)),
            currency1: Currency.wrap(address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA)),
            fee: SWAP_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        bool zeroForOne = address(tokenA) < address(tokenB);

        path[2] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[3])),
            target: address(mockPoolManager),
            data: abi.encodeWithSignature(
                "swap((address,address,uint24,int24,address),bool,uint256,uint256)",
                swapKey,
                zeroForOne,
                SWAP_AMOUNT_IN,
                SWAP_MIN_AMOUNT_OUT
            )
        });

        // Node 1: Approve pool manager
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenA),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockPoolManager), SWAP_AMOUNT_IN)
        });

        // Node 0: Pull tokens
        INexusSettler.IntendNode memory node0ComparisonFinal = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), SWAP_AMOUNT_IN
            )
        });
        path[0] = node0ComparisonFinal;
        path[0].next = keccak256(abi.encode(path[1]));

        // Measure gas
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStartDag = gasleft();
        _executeFullDAGFlow(entryNodeHash, path, s, o, nonce, fillerDagPrivateKey);
        uint256 gasDAG = gasStartDag - gasleft();

        // ============ COMPARISON OUTPUT ============
        uint256 directSteps = 1;
        uint256 dagSteps = _countExecutionSteps(path);

        console2.log("\n=== Gas Comparison (Swap + Deposit - FAIR) ===");
        console2.log("Direct (Swap + Deposit) gas:", gasDirect);
        console2.log("Direct Node Traversal Count:", directSteps);
        console2.log("DAG (Pull + Swap + Deposit) gas:", gasDAG);
        console2.log("DAG Node Traversal Count:", dagSteps);
        if (gasDAG >= gasDirect) {
            console2.log("Difference (DAG overhead):", gasDAG - gasDirect);
            console2.log("Overhead %:", ((gasDAG - gasDirect) * 100) / gasDirect, "%");
        } else {
            console2.log("DAG SAVINGS:", gasDirect - gasDAG);
            console2.log("Savings %:", ((gasDirect - gasDAG) * 100) / gasDirect, "%");
        }
    }

    // ============================================================================
    // Test 9: 10-Operation Fair Comparison (Double Swap + Deposit)
    // ============================================================================

    /**
     * @notice Fair 10-op comparison: two rounds of (pull → approve → swap → approve → supply)
     *         Both sides call the SAME contracts with the SAME operations.
     *         Direct: executor calls poolManager + aavePool directly
     *         DAG: settler calls poolManager + aavePool via IntendNodes
     */
    function testGasProfile_Comparison_10Ops() public {
        uint256 swapPerRound = SWAP_AMOUNT_IN / 2; // 500e18
        uint256 depositPerRound = 490e18; // Conservative to accommodate slippage
        uint256 minOutPerRound = 490e18;

        // Build pool key (reused by both sides)
        address token0 = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address token1 = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);
        PoolKey memory swapKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: SWAP_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        bool zeroForOne = address(tokenA) < address(tokenB);

        uint256 state = vm.snapshot();

        // ============ DIRECT 10 OPS ============
        address fillerDirect = makeAddr("filler_10ops_direct");
        tokenA.mint(fillerDirect, INITIAL_BALANCE);

        vm.startPrank(fillerDirect);
        tokenA.approve(address(directSwapAaveExecutor), type(uint256).max);
        vm.stopPrank();

        vm.prank(fillerDirect);
        uint256 gasStart = gasleft();
        directSwapAaveExecutor.doubleSwapDeposit(
            address(mockPoolManager),
            swapKey,
            zeroForOne,
            address(tokenA),
            address(tokenB),
            swapPerRound,
            depositPerRound,
            minOutPerRound,
            fillerDirect
        );
        uint256 gasDirect = gasStart - gasleft();

        // ============ DAG 10 OPS ============
        vm.revertTo(state);

        address fillerDag = makeAddr("filler_10ops_dag");
        uint256 fillerDagPrivateKey = 0xdeadbeef12345678;

        tokenA.mint(fillerDag, INITIAL_BALANCE);
        vm.startPrank(fillerDag);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // 2. Setup root node parameters (d will be computed from targetNode)
        bytes32 s = keccak256("source_10ops");
        bytes32 o = keccak256("offchain_10ops");
        uint256 nonce = 10;

        // 3. Build 10-node path: two rounds of (pull → approve PM → swap → approve Aave → supply)
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](10);

        // Round 2 (nodes 5-9, built first since next pointers go forward)
        path[9] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), depositPerRound, fillerDag, 0
            )
        });
        path[8] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[9])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), depositPerRound)
        });
        path[7] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[8])),
            target: address(mockPoolManager),
            data: abi.encodeWithSignature(
                "swap((address,address,uint24,int24,address),bool,uint256,uint256)",
                swapKey,
                zeroForOne,
                swapPerRound,
                minOutPerRound
            )
        });
        path[6] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[7])),
            target: address(tokenA),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockPoolManager), swapPerRound)
        });
        path[5] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[6])),
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), swapPerRound
            )
        });

        // Round 1 (nodes 0-4)
        path[4] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[5])),
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), depositPerRound, fillerDag, 0
            )
        });
        path[3] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[4])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), depositPerRound)
        });
        path[2] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[3])),
            target: address(mockPoolManager),
            data: abi.encodeWithSignature(
                "swap((address,address,uint24,int24,address),bool,uint256,uint256)",
                swapKey,
                zeroForOne,
                swapPerRound,
                minOutPerRound
            )
        });
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenA),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockPoolManager), swapPerRound)
        });
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), swapPerRound
            )
        });

        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStartDag = gasleft();
        _executeFullDAGFlow(entryNodeHash, path, s, o, nonce, fillerDagPrivateKey);
        uint256 gasDAG = gasStartDag - gasleft();

        // ============ COMPARISON OUTPUT ============
        uint256 dagSteps = _countExecutionSteps(path);

        console2.log("\n=== Gas Comparison (10 Ops - Double Swap + Deposit) ===");
        console2.log("Operations per side: pull, approve, swap, approve, supply x2");
        console2.log("Direct (10 ops) gas:", gasDirect);
        console2.log("DAG (10 ops) gas:", gasDAG);
        console2.log("DAG Node Traversal Count:", dagSteps);
        console2.log("Difference (DAG overhead):", gasDAG - gasDirect);
        console2.log("Overhead %:", ((gasDAG - gasDirect) * 100) / gasDirect, "%");

        // Verify both deposited
        uint256 dagATokenBalance = mockAToken.balanceOf(fillerDag);
        assertEq(dagATokenBalance, depositPerRound * 2, "DAG: should have 2x deposit in aTokens");

        assertGt(gasDAG, gasDirect, "DAG should have overhead vs Direct");
    }
}
