// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../src/NexusSettler.sol";
import "../src/interfaces/INexusSettler.sol";
import "./mocks/MockV4SwapRouter.sol";
import "./mocks/MockPoolManager.sol";
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
// Mock ERC20 Token
// ============================================================================

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============================================================================
// Mock AToken for Aave Deposit Testing
// ============================================================================

contract MockAToken is ERC20 {
    address public minter;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "Only minter");
        _mint(to, amount);
    }

    function setMinter(address _minter) external {
        require(msg.sender == minter, "Only minter");
        minter = _minter;
    }
}

// ============================================================================
// Mock Aave Pool for Gas Profiling
// ============================================================================

contract MockAavePool {
    using SafeERC20 for IERC20;

    // Track who supplied what amount for each asset
    mapping(address => mapping(address => uint256)) public supplied;

    // Mapping from asset to its corresponding aToken
    mapping(address => address) public aTokenForAsset;

    // Allowed minter (the pool itself)
    address public minter;

    event Supply(address indexed asset, address indexed user, uint256 amount);

    constructor() {
        minter = msg.sender;
    }

    // Set the aToken address for an asset
    function setATokenForAsset(address asset, address aToken) external {
        require(msg.sender == minter, "Only minter");
        aTokenForAsset[asset] = aToken;
    }

    // Internal function to handle supply logic
    function _supply(address asset, uint256 amount, address onBehalfOf) internal {
        supplied[onBehalfOf][asset] += amount;
        address aToken = aTokenForAsset[asset];
        if (aToken != address(0)) {
            MockAToken(aToken).mint(onBehalfOf, amount);
        }
        emit Supply(asset, onBehalfOf, amount);
    }

    // Aave V3 supply function signature
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        _supply(asset, amount, onBehalfOf);
    }

    function getSupplied(address user, address asset) external view returns (uint256) {
        return supplied[user][asset];
    }
}

// ============================================================================
// DirectSwapAaveExecutor
// ============================================================================

/**
 * @title DirectSwapAaveExecutor
 * @notice Reference contract that executes swap then Aave deposit directly
 *         without NexusSettler overhead for gas comparison baseline
 */
contract DirectSwapAaveExecutor {
    using SafeERC20 for IERC20;

    MockV4SwapRouter public immutable SWAP_ROUTER;
    MockAavePool public immutable AAVE_POOL;

    constructor(address swapRouter, address aavePool) {
        SWAP_ROUTER = MockV4SwapRouter(swapRouter);
        AAVE_POOL = MockAavePool(aavePool);
    }

    /**
     * @notice Execute swap then deposit to Aave
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param swapAmount Amount to swap
     * @param depositAmount Amount to deposit to Aave
     * @param beneficiary Address to receive aTokens
     * @param minAmountOut Minimum swap output (slippage protection)
     * @return success True if both operations succeeded
     */
    function execute(
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 depositAmount,
        address beneficiary,
        uint256 minAmountOut
    ) external returns (bool success) {
        // Transfer tokens from caller to executor
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), swapAmount);

        // Approve swap router
        IERC20(tokenIn).approve(address(SWAP_ROUTER), swapAmount);

        // Execute swap - output tokens go to this contract
        uint256 swappedAmount = SWAP_ROUTER.executeSwap(tokenIn, tokenOut, swapAmount, minAmountOut);

        // Approve Aave pool
        IERC20(tokenOut).approve(address(AAVE_POOL), depositAmount);

        // Deposit to Aave
        AAVE_POOL.supply(tokenOut, depositAmount, beneficiary, 0);

        return true;
    }
}

// ============================================================================
// SwapAaveGasProfiler Test
// ============================================================================

contract SwapAaveGasProfiler is Test {
    // NexusSettler and Direct Executor
    NexusSettler public nexusSettler;
    DirectSwapAaveExecutor public directSwapAaveExecutor;

    // Test addresses
    address public escrow;
    address public owner;
    address public filler;

    // Mock contracts
    MockPoolManager public mockPoolManager;
    MockV4SwapRouter public mockV4SwapRouter;
    MockAavePool public mockAavePool;
    MockAToken public mockAToken;

    // Test tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    // Swap constants
    uint24 constant SWAP_FEE = 3000; // 0.3% fee tier

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

        // Deploy DirectSwapAaveExecutor
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

    /// Helper to execute processPIPath with validation
    function _executeProcessPIPath(
        bytes32 rootHash,
        bytes32 targetNodeHash,
        INexusSettler.IntendNode[] memory path,
        bytes32 s,
        bytes32 d,
        bytes32 o,
        uint256 nonce
    ) internal {
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});

        // Build proper chainIdToNode data for single chain (k=1)
        // Format: <k:2><seed:2><chainId:2><hash:32>
        bytes memory chainIdToNode = new bytes(38);
        chainIdToNode[0] = bytes1(uint8(0)); // k = 1 (high byte)
        chainIdToNode[1] = bytes1(uint8(1)); // k = 1 (low byte)
        chainIdToNode[2] = bytes1(uint8(0)); // seed = 0 (high byte)
        chainIdToNode[3] = bytes1(uint8(0)); // seed = 0 (low byte)
        chainIdToNode[4] = bytes1(uint8(uint16(block.chainid) >> 8)); // chainId (high byte)
        chainIdToNode[5] = bytes1(uint8(uint16(block.chainid))); // chainId (low byte)
        // Copy targetNodeHash as the hash (32 bytes) - for k=1 with seed=0, this must be keccak256(abi.encode(path[0]))
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNode[6 + i] = targetNodeHash[i];
        }

        INexusSettler.TargetNode memory targetNode =
            INexusSettler.TargetNode({targetType: INexusSettler.TargetType.Destination, chainIdToNode: chainIdToNode});

        // targetNodeHash must equal keccak256(abi.encode(targetNode))
        bytes32 computedTargetNodeHash = keccak256(abi.encode(targetNode));

        nexusSettler.processPIPath(rootHash, computedTargetNodeHash, path, targetNode, rootNode, nonce);
    }

    // ============================================================================
    // Direct Sequential Gas Profile Tests
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

        // 5. Log results
        console2.log("=== Direct Sequential Gas ===");
        console2.log("Gas used:", gasUsed);

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
    // DAG Graph Gas Profile Tests
    // ============================================================================

    /**
     * @notice Compute EIP-712 digest for testing
     */
    function _computeDigestDAG(bytes32 structHash) internal view returns (bytes32) {
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

        // 2. Create rootHash, signature, nonce for createPI
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));

        // Generate EIP-712 signature
        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigestDAG(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerDagPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        // 3. Call createPI
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        // 4. Create IntendNode[] path with 4 connected nodes:
        // Node 0: Pull tokens from filler to NexusSettler
        // Node 1: Approve pool manager to spend NexusSettler's tokens
        // Node 2: Swap tokenA for tokenB
        // Node 3: Deposit tokenB to Aave
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](4);

        // Node 3: Deposit to Aave (end of path)
        path[3] = INexusSettler.IntendNode({
            next: bytes32(0), // End of path
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
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
        // Note: path[0].next should point to path[1] for traversal
        INexusSettler.IntendNode memory node0 = INexusSettler.IntendNode({
            next: bytes32(0), // placeholder, will be set to hash of path[1]
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), SWAP_AMOUNT_IN
            )
        });
        // Must assign to path[0] first so path[1] is fully initialized
        path[0] = node0;
        // Now set next to point to path[1]
        path[0].next = keccak256(abi.encode(path[1]));

        // 5. Measure gas and execute
        // entryNodeHash is the hash that goes into chainIdToNode (must be keccak256(abi.encode(path[0])))
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStart = gasleft();
        _executeProcessPIPath(rootHash, entryNodeHash, path, s, d, o, nonce);
        uint256 gasUsed = gasStart - gasleft();

        // 6. Log results
        console2.log("=== DAG Graph Gas ===");
        console2.log("Gas used:", gasUsed);

        // 7. Verify state
        // completionKey uses the computed targetNodeHash (keccak256(abi.encode(targetNode)))
        bytes memory chainIdToNodeVerify = new bytes(38);
        chainIdToNodeVerify[0] = bytes1(uint8(0));
        chainIdToNodeVerify[1] = bytes1(uint8(1));
        chainIdToNodeVerify[2] = bytes1(uint8(0));
        chainIdToNodeVerify[3] = bytes1(uint8(0));
        chainIdToNodeVerify[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNodeVerify[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNodeVerify[6 + i] = entryNodeHash[i];
        }
        INexusSettler.TargetNode memory targetNodeVerify = INexusSettler.TargetNode({
            targetType: INexusSettler.TargetType.Destination,
            chainIdToNode: chainIdToNodeVerify
        });
        bytes32 computedTargetNodeHash = keccak256(abi.encode(targetNodeVerify));
        bytes32 completionKey = keccak256(abi.encode(rootHash, computedTargetNodeHash));
        assertTrue(nexusSettler.completed(completionKey), "Path should be completed");

        // Verify filler has aTokens
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDag);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        // Verify pool received tokenB
        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDag, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");
    }

    // ============================================================================
    // Gas Comparison Tests
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

        // Create intent
        bytes32 s = keccak256("source");
        bytes32 d = keccak256("destination");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));

        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigestDAG(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerDagPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        // Create 4-node path (same as DAG test)
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](4);

        // Node 3: Deposit
        path[3] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
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

        // Node 1: Approve
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenA),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockPoolManager), SWAP_AMOUNT_IN)
        });

        // Node 0: Pull tokens
        // Note: path[0].next should point to path[1] for traversal
        INexusSettler.IntendNode memory node0ComparisonSwap = INexusSettler.IntendNode({
            next: bytes32(0), // placeholder, will be set to hash of path[1]
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), SWAP_AMOUNT_IN
            )
        });
        // Must assign to path[0] first so path[1] is fully initialized
        path[0] = node0ComparisonSwap;
        // Now set next to point to path[1]
        path[0].next = keccak256(abi.encode(path[1]));

        // Measure gas
        // entryNodeHash is the hash that goes into chainIdToNode (must be keccak256(abi.encode(path[0])))
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStartDag = gasleft();
        _executeProcessPIPath(rootHash, entryNodeHash, path, s, d, o, nonce);
        uint256 gasDAG = gasStartDag - gasleft();

        // ============ COMPARISON OUTPUT ============
        console2.log("\n=== Gas Comparison (Swap + Aave Deposit) ===");
        console2.log("Direct Sequential gas:", gasDirect);
        console2.log("DAG Graph gas:", gasDAG);
        console2.log("Difference (DAG overhead):", gasDAG - gasDirect);
        console2.log("Overhead %:", ((gasDAG - gasDirect) * 100) / gasDirect, "%");

        // Verify DAG gas is higher (expected overhead)
        assertGt(gasDAG, gasDirect, "DAG should have overhead vs Direct");
    }

    // ============================================================================
    // Deposit Only Flow Tests (DAG vs Direct)
    // ============================================================================

    /**
     * @notice Profile gas for direct Aave deposit only (no swap)
     *         Baseline measurement for deposit-only flow
     */
    function testGasProfile_DirectAaveDepositOnly() public {
        // 1. Create fresh filler
        address fillerDirect = makeAddr("filler_direct_deposit_only");

        // 2. Mint tokenB directly to filler (skip swap)
        tokenB.mint(fillerDirect, INITIAL_BALANCE);

        // 3. Setup approvals
        vm.startPrank(fillerDirect);
        tokenB.approve(address(mockAavePool), type(uint256).max);
        vm.stopPrank();

        // 4. Measure gas for direct deposit only
        vm.prank(fillerDirect);
        uint256 gasStart = gasleft();

        mockAavePool.supply(address(tokenB), DEPOSIT_AMOUNT, fillerDirect, 0);

        uint256 gasUsed = gasStart - gasleft();

        // 5. Log results
        console2.log("=== Direct Aave Deposit Only Gas ===");
        console2.log("Gas used:", gasUsed);

        // 6. Verify state
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDirect);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDirect, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");
    }

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

        // 2. Create rootHash, signature, nonce for createPI
        bytes32 s = keccak256("source_deposit_only");
        bytes32 d = keccak256("destination_deposit_only");
        bytes32 o = keccak256("offchain_deposit_only");
        uint256 nonce = 2;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));

        // Generate EIP-712 signature
        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigestDAG(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerDagPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        // 3. Call createPI
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        // 4. Create IntendNode[] path with 2 connected nodes:
        // Node 0: Pull tokenB from filler to NexusSettler
        // Node 1: Deposit tokenB to Aave
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](2);

        // Node 1: Deposit to Aave (end of path)
        path[1] = INexusSettler.IntendNode({
            next: bytes32(0), // End of path
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 0: Pull tokenB from filler to NexusSettler (points to node 1)
        // Note: path[0].next should point to path[1] for traversal
        INexusSettler.IntendNode memory node0DepositOnly = INexusSettler.IntendNode({
            next: bytes32(0), // placeholder, will be set to hash of path[1]
            target: address(tokenB),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), DEPOSIT_AMOUNT
            )
        });
        // Must assign to path[0] first so path[1] is fully initialized
        path[0] = node0DepositOnly;
        // Now set next to point to path[1]
        path[0].next = keccak256(abi.encode(path[1]));

        // 5. Measure gas and execute
        // entryNodeHash is the hash that goes into chainIdToNode (must be keccak256(abi.encode(path[0])))
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStart = gasleft();
        _executeProcessPIPath(rootHash, entryNodeHash, path, s, d, o, nonce);
        uint256 gasUsed = gasStart - gasleft();

        // 6. Log results
        console2.log("=== DAG Graph Gas (Deposit Only) ===");
        console2.log("Gas used:", gasUsed);

        // 7. Verify state
        // completionKey uses the computed targetNodeHash (keccak256(abi.encode(targetNode)))
        bytes memory chainIdToNodeVerify = new bytes(38);
        chainIdToNodeVerify[0] = bytes1(uint8(0));
        chainIdToNodeVerify[1] = bytes1(uint8(1));
        chainIdToNodeVerify[2] = bytes1(uint8(0));
        chainIdToNodeVerify[3] = bytes1(uint8(0));
        chainIdToNodeVerify[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNodeVerify[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNodeVerify[6 + i] = entryNodeHash[i];
        }
        INexusSettler.TargetNode memory targetNodeVerify = INexusSettler.TargetNode({
            targetType: INexusSettler.TargetType.Destination,
            chainIdToNode: chainIdToNodeVerify
        });
        bytes32 computedTargetNodeHash = keccak256(abi.encode(targetNodeVerify));
        bytes32 completionKey = keccak256(abi.encode(rootHash, computedTargetNodeHash));
        assertTrue(nexusSettler.completed(completionKey), "Path should be completed");

        // Verify filler has aTokens
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDag);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        // Verify pool received tokenB
        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDag, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");
    }

    /**
     * @notice Compare direct Aave deposit vs DAG deposit-only flow
     *         Uses vm.snapshot() for fair comparison
     */
    function testGasProfile_Comparison_DepositOnly() public {
        // Use vm.snapshot() for fair comparison
        uint256 state = vm.snapshot();

        // ============ DIRECT AAVE DEPOSIT ONLY ============
        address fillerDirect = makeAddr("filler_comparison_direct_deposit");

        // Setup fresh filler with tokenB
        tokenB.mint(fillerDirect, INITIAL_BALANCE);
        vm.startPrank(fillerDirect);
        tokenB.approve(address(mockAavePool), type(uint256).max);
        vm.stopPrank();

        // Measure gas
        vm.prank(fillerDirect);
        uint256 gasStart = gasleft();
        mockAavePool.supply(address(tokenB), DEPOSIT_AMOUNT, fillerDirect, 0);
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

        // Create intent
        bytes32 s = keccak256("source_comparison");
        bytes32 d = keccak256("destination_comparison");
        bytes32 o = keccak256("offchain_comparison");
        uint256 nonce = 3;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));

        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigestDAG(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerDagPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        // Create 2-node path (pull -> deposit)
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](2);

        // Node 1: Deposit
        path[1] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 0: Pull tokens
        // Note: path[0].next should point to path[1] for traversal
        INexusSettler.IntendNode memory node0Comparison = INexusSettler.IntendNode({
            next: bytes32(0), // placeholder, will be set to hash of path[1]
            target: address(tokenB),  // Should be tokenB for deposit-only flow
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), DEPOSIT_AMOUNT
            )
        });
        // Must assign to path[0] first so path[1] is fully initialized
        path[0] = node0Comparison;
        // Now set next to point to path[1]
        path[0].next = keccak256(abi.encode(path[1]));

        // Measure gas
        // entryNodeHash is the hash that goes into chainIdToNode (must be keccak256(abi.encode(path[0])))
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStartDag = gasleft();
        _executeProcessPIPath(rootHash, entryNodeHash, path, s, d, o, nonce);
        uint256 gasDAG = gasStartDag - gasleft();

        // ============ COMPARISON OUTPUT ============
        console2.log("\n=== Gas Comparison (Deposit Only) ===");
        console2.log("Direct Aave Deposit Only gas:", gasDirect);
        console2.log("DAG (Deposit Only) gas:", gasDAG);
        console2.log("Difference (DAG overhead):", gasDAG - gasDirect);
        console2.log("Overhead %:", ((gasDAG - gasDirect) * 100) / gasDirect, "%");

        // Verify DAG gas is higher (expected overhead)
        assertGt(gasDAG, gasDirect, "DAG should have overhead vs Direct");
    }

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

        // 2. Create rootHash, signature, nonce for createPI
        bytes32 s = keccak256("source_deposit_swap");
        bytes32 d = keccak256("destination_deposit_swap");
        bytes32 o = keccak256("offchain_deposit_swap");
        uint256 nonce = 2;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));

        // Generate EIP-712 signature
        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigestDAG(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerDagPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        // 3. Call createPI
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        // 4. Create IntendNode[] path with 5 connected nodes:
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
        // Note: path[0].next should point to path[1] for traversal
        INexusSettler.IntendNode memory node0DepositSwapDeposit = INexusSettler.IntendNode({
            next: bytes32(0), // placeholder, will be set to hash of path[1]
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), SWAP_AMOUNT_IN
            )
        });
        // Must assign to path[0] first so path[1] is fully initialized
        path[0] = node0DepositSwapDeposit;
        // Now set next to point to path[1]
        path[0].next = keccak256(abi.encode(path[1]));

        // 5. Measure gas and execute
        // entryNodeHash is the hash that goes into chainIdToNode (must be keccak256(abi.encode(path[0])))
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStart = gasleft();
        _executeProcessPIPath(rootHash, entryNodeHash, path, s, d, o, nonce);
        uint256 gasUsed = gasStart - gasleft();

        // 6. Log results
        console2.log("=== DAG Graph Gas (Deposit -> Swap -> Deposit) ===");
        console2.log("Gas used:", gasUsed);

        // 7. Verify state
        // completionKey uses the computed targetNodeHash (keccak256(abi.encode(targetNode)))
        bytes memory chainIdToNodeVerifyDSD = new bytes(38);
        chainIdToNodeVerifyDSD[0] = bytes1(uint8(0));
        chainIdToNodeVerifyDSD[1] = bytes1(uint8(1));
        chainIdToNodeVerifyDSD[2] = bytes1(uint8(0));
        chainIdToNodeVerifyDSD[3] = bytes1(uint8(0));
        chainIdToNodeVerifyDSD[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNodeVerifyDSD[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNodeVerifyDSD[6 + i] = entryNodeHash[i];
        }
        INexusSettler.TargetNode memory targetNodeVerifyDSD = INexusSettler.TargetNode({
            targetType: INexusSettler.TargetType.Destination,
            chainIdToNode: chainIdToNodeVerifyDSD
        });
        bytes32 computedTargetNodeHashDSD = keccak256(abi.encode(targetNodeVerifyDSD));
        bytes32 completionKey = keccak256(abi.encode(rootHash, computedTargetNodeHashDSD));
        assertTrue(nexusSettler.completed(completionKey), "Path should be completed");

        // Verify filler has aTokens
        uint256 aTokenBalance = mockAToken.balanceOf(fillerDag);
        assertEq(aTokenBalance, DEPOSIT_AMOUNT, "Filler should have received aTokens");

        // Verify pool received tokenB
        uint256 poolTokenBBalance = mockAavePool.supplied(fillerDag, address(tokenB));
        assertEq(poolTokenBBalance, DEPOSIT_AMOUNT, "Pool should have received tokenB deposit");
    }

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

        // Create intent
        bytes32 s = keccak256("source_comparison");
        bytes32 d = keccak256("destination_comparison");
        bytes32 o = keccak256("offchain_comparison");
        uint256 nonce = 3;
        bytes32 rootHash = keccak256(abi.encode(s, d, o, nonce));

        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigestDAG(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerDagPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        // Create 5-node path (pull -> approve -> swap -> approve -> deposit)
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
        // Note: path[0].next should point to path[1] for traversal
        INexusSettler.IntendNode memory node0ComparisonFinal = INexusSettler.IntendNode({
            next: bytes32(0), // placeholder, will be set to hash of path[1]
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), SWAP_AMOUNT_IN
            )
        });
        // Must assign to path[0] first so path[1] is fully initialized
        path[0] = node0ComparisonFinal;
        // Now set next to point to path[1]
        path[0].next = keccak256(abi.encode(path[1]));

        // Measure gas
        // entryNodeHash is the hash that goes into chainIdToNode (must be keccak256(abi.encode(path[0])))
        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        vm.prank(fillerDag);
        uint256 gasStartDag = gasleft();
        _executeProcessPIPath(rootHash, entryNodeHash, path, s, d, o, nonce);
        uint256 gasDAG = gasStartDag - gasleft();

        // ============ COMPARISON OUTPUT ============
        console2.log("\n=== Gas Comparison (Swap + Deposit - FAIR) ===");
        console2.log("Direct (Swap + Deposit) gas:", gasDirect);
        console2.log("DAG (Pull + Swap + Deposit) gas:", gasDAG);
        console2.log("Difference (DAG overhead):", gasDAG - gasDirect);
        console2.log("Overhead %:", ((gasDAG - gasDirect) * 100) / gasDirect, "%");

        // Verify DAG gas is higher (expected overhead)
        assertGt(gasDAG, gasDirect, "DAG should have overhead vs Direct");
    }
}
