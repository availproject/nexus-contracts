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
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external {
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
        uint256 swappedAmount = SWAP_ROUTER.executeSwap(
            tokenIn,
            tokenOut,
            swapAmount,
            minAmountOut
        );

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
        directSwapAaveExecutor = new DirectSwapAaveExecutor(
            address(mockV4SwapRouter),
            address(mockAavePool)
        );

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
            address(tokenA),            // tokenIn
            address(tokenB),             // tokenOut
            SWAP_AMOUNT_IN,              // swapAmount
            DEPOSIT_AMOUNT,              // depositAmount
            fillerDirect,                // beneficiary (receives aTokens)
            SWAP_MIN_AMOUNT_OUT          // minAmountOut (slippage protection)
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
}
