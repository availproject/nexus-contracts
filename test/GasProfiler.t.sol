// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../src/NexusSettler.sol";
import "../src/interfaces/INexusSettler.sol";
import "../src/interfaces/IActionRouter.sol";
import "../src/routers/UniswapV4Router.sol";
import "./mocks/MockUniversalRouter.sol";
import "./mocks/MockPoolManager.sol";
import "./mocks/MockV4SwapRouter.sol";
import "./mocks/MockPermit2.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock AToken for Aave deposit testing - minter restricted to MockAavePool
contract MockAToken is ERC20 {
    address public minter;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        minter = msg.sender; // Deployer is minter
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

// Mock Aave Pool for gas profiling - simulates Aave V3 supply behavior
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

    // Set the aToken address for an asset (called during test setup)
    function setATokenForAsset(address asset, address aToken) external {
        require(msg.sender == minter, "Only minter");
        aTokenForAsset[asset] = aToken;
    }

    // Execute function to handle action calls from NexusSettler (IActionRouter interface)
    function execute(
        INexusSettler.Action calldata action,
        bytes calldata /* data */
    ) external payable returns (bytes memory) {
        // The action.callData contains the supply function selector + parameters
        // Skip the first 4 bytes (function selector) and decode parameters
        bytes calldata params = action.callData[4:];
        (address asset, uint256 amount, address onBehalfOf, uint16 referralCode) = abi.decode(
            params,
            (address, uint256, address, uint16)
        );
        _supply(asset, amount, onBehalfOf);
        return "";
    }

    // Internal function to handle supply logic
    // Note: Tokens are already transferred to this contract via Fund in the intent
    // So we only need to track supply and mint aTokens
    function _supply(address asset, uint256 amount, address onBehalfOf) internal {
        // Tokens already transferred via Fund - just track supply
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
        uint16 referralCode // Unused but included for interface compatibility
    ) external {
        _supply(asset, amount, onBehalfOf);
    }

    function getSupplied(address user, address asset) external view returns (uint256) {
        return supplied[user][asset];
    }
}

// DirectFill: performs the same token operations as NexusSettler.fill()
// but without the settler contract abstraction/overhead
contract DirectFill {
    using SafeERC20 for IERC20;

    address public escrow;

    constructor(address _escrow) {
        escrow = _escrow;
    }

    // Direct fill operation - same logic as NexusSettler.fill() but without:
    // - orderId validation
    // - ordersFilled mapping check/update
    // - domain parsing and validation
    // - balance tracking for outputs
    // - intent decoding overhead
    function directFill(
        address owner,
        DirectFillData calldata data
    ) external {
        // Execute conditions (external calls)
        for (uint256 i = 0; i < data.conditions.length; ) {
            DirectAction memory action = data.conditions[i];
            (bool success, ) = action.target.call{value: action.value}(action.callData);
            require(success, "Condition failed");
            unchecked {
                ++i;
            }
        }

        // Execute locks (transfer to escrow)
        for (uint256 i = 0; i < data.locks.length; ) {
            DirectLock memory lock = data.locks[i];
            IERC20(lock.token).safeTransferFrom(owner, escrow, lock.amount);
            unchecked {
                ++i;
            }
        }

        // Execute funds (transfer from filler to recipients)
        for (uint256 i = 0; i < data.funds.length; ) {
            DirectFund memory fund = data.funds[i];
            IERC20(fund.token).safeTransferFrom(msg.sender, fund.recipient, fund.amount);
            unchecked {
                ++i;
            }
        }

        // Execute actions (arbitrary calls)
        for (uint256 i = 0; i < data.actions.length; ) {
            DirectAction memory action = data.actions[i];
            (bool success, ) = action.target.call{value: action.value}(action.callData);
            require(success, "Action failed");
            unchecked {
                ++i;
            }
        }
    }
}

// Data structures for DirectFill
struct DirectAction {
    address target;
    bytes callData;
    uint256 value;
}

struct DirectLock {
    address token;
    uint256 amount;
}

struct DirectFund {
    address token;
    address recipient;
    uint256 amount;
}

struct DirectFillData {
    DirectAction[] conditions;
    DirectLock[] locks;
    DirectFund[] funds;
    DirectAction[] actions;
}

contract GasProfilerTest is Test {
    NexusSettler public nexusSettler;
    DirectFill public directFill;
    address public escrow;
    
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    
    address public owner;
    address public filler;
    address public recipient1;
    address public recipient2;
    
    // Test data
    bytes32 constant ORDER_ID = keccak256("test_order");
    uint256 constant INITIAL_BALANCE = 1000000e18;
    uint256 constant LOCK_AMOUNT = 100e18;
    uint256 constant FUND_AMOUNT = 50e18;

    // Swap testing infrastructure
    UniswapV4Router public uniswapV4Router;
    MockUniversalRouter public mockUniversalRouter;
    MockPoolManager public mockPoolManager;
    MockV4SwapRouter public mockV4SwapRouter;
    MockPermit2 public mockPermit2;

    // Swap constants
    uint256 constant SWAP_AMOUNT_IN = 1000e18;
    uint256 constant SWAP_MIN_AMOUNT_OUT = 995e18; // ~0.5% slippage (actual output ~996 tokens)
    uint24 constant SWAP_FEE = 3000; // 0.3% fee tier

    function setUp() public {
        // Setup addresses
        escrow = makeAddr("escrow");
        owner = makeAddr("owner");
        filler = makeAddr("filler");
        recipient1 = makeAddr("recipient1");
        recipient2 = makeAddr("recipient2");
        
        // Deploy contracts
        nexusSettler = new NexusSettler(escrow);
        directFill = new DirectFill(escrow);
        
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKA");
        tokenB = new MockERC20("Token B", "TKB");
        tokenC = new MockERC20("Token C", "TKC");
        
        // Mint tokens to owner and filler
        tokenA.mint(owner, INITIAL_BALANCE);
        tokenA.mint(filler, INITIAL_BALANCE);
        tokenB.mint(owner, INITIAL_BALANCE);
        tokenB.mint(filler, INITIAL_BALANCE);
        tokenC.mint(owner, INITIAL_BALANCE);
        tokenC.mint(filler, INITIAL_BALANCE);
        
        // Approve tokens for NexusSettler and DirectFill
        vm.startPrank(owner);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenA.approve(address(directFill), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(directFill), type(uint256).max);
        tokenC.approve(address(nexusSettler), type(uint256).max);
        tokenC.approve(address(directFill), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(filler);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenA.approve(address(directFill), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(directFill), type(uint256).max);
        tokenC.approve(address(nexusSettler), type(uint256).max);
        tokenC.approve(address(directFill), type(uint256).max);
        vm.stopPrank();

        // Deploy mock contracts for swap testing
        mockPoolManager = new MockPoolManager();
        mockPermit2 = new MockPermit2();
        mockUniversalRouter = new MockUniversalRouter(address(mockPoolManager), address(mockPermit2));
        mockV4SwapRouter = new MockV4SwapRouter(address(mockPoolManager));

        // Deploy UniswapV4Router with mock UniversalRouter and mock Permit2
        uniswapV4Router = new UniswapV4Router(address(mockUniversalRouter), address(mockPermit2));

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
        tokenA.mint(address(this), 1000000e18);
        tokenB.mint(address(this), 1000000e18);
        
        // Approve pool manager
        IERC20(token0).approve(address(mockPoolManager), type(uint256).max);
        IERC20(token1).approve(address(mockPoolManager), type(uint256).max);
        
        // Initialize pool
        mockPoolManager.initializePool(key, 1000000e18, 1000000e18);
        
        // Approve tokens for swap routers
        vm.startPrank(owner);
        tokenA.approve(address(mockUniversalRouter), type(uint256).max);
        tokenA.approve(address(mockV4SwapRouter), type(uint256).max);
        tokenB.approve(address(mockUniversalRouter), type(uint256).max);
        tokenB.approve(address(mockV4SwapRouter), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(filler);
        tokenA.approve(address(mockUniversalRouter), type(uint256).max);
        tokenA.approve(address(mockV4SwapRouter), type(uint256).max);
        tokenB.approve(address(mockUniversalRouter), type(uint256).max);
        tokenB.approve(address(mockV4SwapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function createTestIntent() internal view returns (INexusSettler.Intent memory) {
        // Create a batch for the local domain
        INexusSettler.Action[] memory conditions = new INexusSettler.Action[](0);
        
        INexusSettler.Lock[] memory locks = new INexusSettler.Lock[](1);
        locks[0] = INexusSettler.Lock({
            token: bytes32(bytes20(address(tokenA))),
            amount: LOCK_AMOUNT
        });
        
        INexusSettler.Fund[] memory funds = new INexusSettler.Fund[](1);
        funds[0] = INexusSettler.Fund({
            recipient: bytes32(bytes20(recipient1)),
            token: bytes32(bytes20(address(tokenB))),
            amount: FUND_AMOUNT
        });
        
        INexusSettler.Action[] memory actions = new INexusSettler.Action[](0);
        
        INexusSettler.Actions memory batch = INexusSettler.Actions({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            settler: bytes32(bytes20(address(nexusSettler))),
            conditions: conditions,
            locks: locks,
            funds: funds,
            actions: actions,
            fees: INexusSettler.Fees(bytes32(0), 0)
        });
        
        INexusSettler.Actions[] memory batches = new INexusSettler.Actions[](1);
        batches[0] = batch;
        
        // Create outputs for validation
        INexusSettler.Resource[] memory inputs = new INexusSettler.Resource[](0);
        INexusSettler.Resource[] memory outputs = new INexusSettler.Resource[](0);
        
        return INexusSettler.Intent({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            batches: batches,
            sender: bytes32(bytes20(owner)),
            recipient: bytes32(bytes20(recipient1)),
            nonce: 1,
            inputs: inputs,
            outputs: outputs
        });
    }

    function createDirectFillData() internal view returns (DirectFillData memory) {
        DirectAction[] memory conditions = new DirectAction[](0);
        
        DirectLock[] memory locks = new DirectLock[](1);
        locks[0] = DirectLock({
            token: address(tokenA),
            amount: LOCK_AMOUNT
        });
        
        DirectFund[] memory funds = new DirectFund[](1);
        funds[0] = DirectFund({
            token: address(tokenB),
            recipient: recipient1,
            amount: FUND_AMOUNT
        });
        
        DirectAction[] memory actions = new DirectAction[](0);
        
        return DirectFillData({
            conditions: conditions,
            locks: locks,
            funds: funds,
            actions: actions
        });
    }

    // ============ Gas Profiling Tests ============

    function testGasProfile_NexusSettlerFill_Simple() public {
        // Setup: Create intent and order
        INexusSettler.Intent memory intent = createTestIntent();
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);
        
        // First open the order
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });
        
        vm.prank(owner);
        nexusSettler.open(order);
        
        // Profile gas for fill operation
        vm.prank(filler);
        uint256 gasStart = gasleft();
        nexusSettler.fill(orderId, originData, "");
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("=== NexusSettler.fill() Gas Profile (Simple) ===");
        console2.log("Gas used:", gasUsed);
    }

    function testGasProfile_DirectFill_Simple() public {
        // Setup: Create direct fill data
        DirectFillData memory data = createDirectFillData();
        
        // Profile gas for direct fill operation
        vm.prank(filler);
        uint256 gasStart = gasleft();
        directFill.directFill(owner, data);
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("=== DirectFill.directFill() Gas Profile (Simple) ===");
        console2.log("Gas used:", gasUsed);
    }

    function testGasProfile_AaveDeposit_Direct() public {
        // This test shows the absolute baseline: pure ERC20 transfers without ANY contract overhead
        // No DirectFill contract, no NexusSettler - just direct token transfers
        
        // Reset state - ensure owner and filler have tokens (from setUp)
        tokenA.mint(owner, LOCK_AMOUNT);
        tokenA.mint(filler, LOCK_AMOUNT);
        
        // Profile the actual transfers (lock + action)
        uint256 gasStart = gasleft();
        
        // Lock: owner -> escrow (simulating the lock into escrow)
        vm.prank(owner);
        tokenA.transfer(escrow, LOCK_AMOUNT);
        
        // Action: filler -> recipient (simulating the deposit/transfer)
        vm.prank(filler);
        tokenA.transfer(recipient1, LOCK_AMOUNT);
        
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("=== Direct Aave Deposit Gas Profile (No Contract) ===");
        console2.log("Gas used:", gasUsed);
    }

    function testGasProfile_Comparison_Simple() public {
        // Setup: Create intent and order for NexusSettler
        INexusSettler.Intent memory intent = createTestIntent();
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);
        
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });
        
        // Reset state for fair comparison - use fresh filler for each
        address filler1 = makeAddr("filler1");
        tokenA.mint(filler1, INITIAL_BALANCE);
        tokenB.mint(filler1, INITIAL_BALANCE);
        vm.startPrank(filler1);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();
        
        vm.prank(owner);
        nexusSettler.open(order);
        
        vm.prank(filler1);
        uint256 gasNexus = gasleft();
        nexusSettler.fill(orderId, originData, "");
        gasNexus = gasNexus - gasleft();
        
        // Reset state for DirectFill
        address filler2 = makeAddr("filler2");
        tokenA.mint(filler2, INITIAL_BALANCE);
        tokenB.mint(filler2, INITIAL_BALANCE);
        vm.startPrank(filler2);
        tokenA.approve(address(directFill), type(uint256).max);
        tokenB.approve(address(directFill), type(uint256).max);
        vm.stopPrank();
        
        DirectFillData memory data = createDirectFillData();
        
        vm.prank(filler2);
        uint256 gasDirect = gasleft();
        directFill.directFill(owner, data);
        gasDirect = gasDirect - gasleft();
        
        // Report comparison
        console2.log("\n=== Gas Comparison (Simple - 1 lock, 1 fund) ===");
        console2.log("NexusSettler.fill() gas used:", gasNexus);
        console2.log("DirectFill.directFill() gas used:", gasDirect);
        console2.log("Difference (Nexus overhead):", gasNexus - gasDirect);
        console2.log("Overhead percentage:", ((gasNexus - gasDirect) * 100) / gasDirect, "%");
    }

    // ============ Complex Scenarios ============

    function testGasProfile_Comparison_Complex() public {
        // Setup: Create complex intent with multiple locks, funds, and actions
        INexusSettler.Action[] memory conditions = new INexusSettler.Action[](0);
        
        INexusSettler.Lock[] memory locks = new INexusSettler.Lock[](3);
        locks[0] = INexusSettler.Lock({token: bytes32(bytes20(address(tokenA))), amount: LOCK_AMOUNT});
        locks[1] = INexusSettler.Lock({token: bytes32(bytes20(address(tokenB))), amount: LOCK_AMOUNT});
        locks[2] = INexusSettler.Lock({token: bytes32(bytes20(address(tokenC))), amount: LOCK_AMOUNT});
        
        INexusSettler.Fund[] memory funds = new INexusSettler.Fund[](2);
        funds[0] = INexusSettler.Fund({
            recipient: bytes32(bytes20(recipient1)),
            token: bytes32(bytes20(address(tokenA))),
            amount: FUND_AMOUNT
        });
        funds[1] = INexusSettler.Fund({
            recipient: bytes32(bytes20(recipient2)),
            token: bytes32(bytes20(address(tokenB))),
            amount: FUND_AMOUNT
        });
        
        INexusSettler.Action[] memory actions = new INexusSettler.Action[](0);
        
        INexusSettler.Actions memory batch = INexusSettler.Actions({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            settler: bytes32(bytes20(address(nexusSettler))),
            conditions: conditions,
            locks: locks,
            funds: funds,
            actions: actions,
            fees: INexusSettler.Fees(bytes32(0), 0)
        });
        
        INexusSettler.Actions[] memory batches = new INexusSettler.Actions[](1);
        batches[0] = batch;
        
        INexusSettler.Resource[] memory inputs = new INexusSettler.Resource[](0);
        INexusSettler.Resource[] memory outputs = new INexusSettler.Resource[](0);
        
        INexusSettler.Intent memory intent = INexusSettler.Intent({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            batches: batches,
            sender: bytes32(bytes20(owner)),
            recipient: bytes32(bytes20(recipient1)),
            nonce: 1,
            inputs: inputs,
            outputs: outputs
        });
        
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);
        
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });
        
        // Test NexusSettler
        address filler1 = makeAddr("filler1_complex");
        tokenA.mint(filler1, INITIAL_BALANCE);
        tokenB.mint(filler1, INITIAL_BALANCE);
        vm.startPrank(filler1);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();
        
        vm.prank(owner);
        nexusSettler.open(order);
        
        vm.prank(filler1);
        uint256 gasNexus = gasleft();
        nexusSettler.fill(orderId, originData, "");
        gasNexus = gasNexus - gasleft();
        
        // Test DirectFill
        address filler2 = makeAddr("filler2_complex");
        tokenA.mint(filler2, INITIAL_BALANCE);
        tokenB.mint(filler2, INITIAL_BALANCE);
        tokenC.mint(filler2, INITIAL_BALANCE);
        vm.startPrank(filler2);
        tokenA.approve(address(directFill), type(uint256).max);
        tokenB.approve(address(directFill), type(uint256).max);
        tokenC.approve(address(directFill), type(uint256).max);
        vm.stopPrank();
        
        DirectLock[] memory dLocks = new DirectLock[](3);
        dLocks[0] = DirectLock({token: address(tokenA), amount: LOCK_AMOUNT});
        dLocks[1] = DirectLock({token: address(tokenB), amount: LOCK_AMOUNT});
        dLocks[2] = DirectLock({token: address(tokenC), amount: LOCK_AMOUNT});
        
        DirectFund[] memory dFunds = new DirectFund[](2);
        dFunds[0] = DirectFund({token: address(tokenA), recipient: recipient1, amount: FUND_AMOUNT});
        dFunds[1] = DirectFund({token: address(tokenB), recipient: recipient2, amount: FUND_AMOUNT});
        
        DirectFillData memory data = DirectFillData({
            conditions: new DirectAction[](0),
            locks: dLocks,
            funds: dFunds,
            actions: new DirectAction[](0)
        });
        
        vm.prank(filler2);
        uint256 gasDirect = gasleft();
        directFill.directFill(owner, data);
        gasDirect = gasDirect - gasleft();
        
        // Report comparison
        console2.log("\n=== Gas Comparison (Complex - 3 locks, 2 funds) ===");
        console2.log("NexusSettler.fill() gas used:", gasNexus);
        console2.log("DirectFill.directFill() gas used:", gasDirect);
        console2.log("Difference (Nexus overhead):", gasNexus - gasDirect);
        console2.log("Overhead percentage:", ((gasNexus - gasDirect) * 100) / gasDirect, "%");
    }

    // ============ Aave Deposit Gas Profile ============

    function testGasProfile_AaveDeposit_NexusSettler() public {
        // Deploy MockAavePool
        MockAavePool aavePool = new MockAavePool();
        
        // Deploy aToken for tokenA
        MockAToken aTokenA = new MockAToken("aToken A", "aTKA");
        aTokenA.setMinter(address(aavePool));
        aavePool.setATokenForAsset(address(tokenA), address(aTokenA));
        
        // Setup: Approve tokens for owner (for lock) and filler (for fund)
        vm.startPrank(owner);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(filler);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();
        
        // Create Intent with supply action
        INexusSettler.Action[] memory conditions = new INexusSettler.Action[](0);
        
        // Lock: owner locks tokens to escrow
        INexusSettler.Lock[] memory locks = new INexusSettler.Lock[](1);
        locks[0] = INexusSettler.Lock({
            token: bytes32(bytes20(address(tokenA))),
            amount: LOCK_AMOUNT
        });
        
        // Fund: filler provides tokens for the supply action
        INexusSettler.Fund[] memory funds = new INexusSettler.Fund[](1);
        funds[0] = INexusSettler.Fund({
            recipient: bytes32(bytes20(address(aavePool))), // Send to AavePool
            token: bytes32(bytes20(address(tokenA))),
            amount: LOCK_AMOUNT
        });
        
        // Create supply action
        INexusSettler.Action[] memory actions = new INexusSettler.Action[](1);
        bytes memory supplyCallData = abi.encodeWithSelector(
            MockAavePool.supply.selector,
            address(tokenA),
            LOCK_AMOUNT,
            owner,  // onBehalfOf
            uint16(0)  // referralCode
        );
        actions[0] = INexusSettler.Action({
            actionType: INexusSettler.ActionType.SWAP,  // Using SWAP as arbitrary action
            target: Strings.toHexString(uint256(uint160(address(aavePool))), 20),
            callData: supplyCallData,
            value: 0
        });
        
        INexusSettler.Actions memory batch = INexusSettler.Actions({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            settler: bytes32(bytes20(address(nexusSettler))),
            conditions: conditions,
            locks: locks,
            funds: funds,
            actions: actions,
            fees: INexusSettler.Fees(bytes32(0), 0)
        });
        
        INexusSettler.Actions[] memory batches = new INexusSettler.Actions[](1);
        batches[0] = batch;
        
        INexusSettler.Resource[] memory inputs = new INexusSettler.Resource[](0);
        INexusSettler.Resource[] memory outputs = new INexusSettler.Resource[](0);
        
        INexusSettler.Intent memory intent = INexusSettler.Intent({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            batches: batches,
            sender: bytes32(bytes20(owner)),
            recipient: bytes32(bytes20(owner)),
            nonce: 1,
            inputs: inputs,
            outputs: outputs
        });
        
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);
        
        // Create and open order
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });
        
        vm.prank(owner);
        nexusSettler.open(order);
        
        // Profile gas for fill operation
        vm.prank(filler);
        uint256 gasStart = gasleft();
        nexusSettler.fill(orderId, originData, "");
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("=== NexusSettler Aave Deposit Gas Profile ===");
        console2.log("Gas used:", gasUsed);
    }

    function testGasProfile_AaveDeposit_Comparison() public {
        // Setup: Deploy MockAavePool and aToken
        MockAavePool aavePool = new MockAavePool();
        MockAToken aTokenA = new MockAToken("aToken A", "aTKA");
        aTokenA.setMinter(address(aavePool));
        aavePool.setATokenForAsset(address(tokenA), address(aTokenA));
        
        // ============ NEXUS SETTLER FLOW ============
        address filler1 = makeAddr("filler1_aave");
        
        // Setup tokens and approvals for filler1
        tokenA.mint(filler1, INITIAL_BALANCE);
        vm.startPrank(filler1);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();
        
        // Setup owner approval
        vm.startPrank(owner);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();
        
        // Create Intent with supply action
        INexusSettler.Action[] memory conditions = new INexusSettler.Action[](0);
        
        INexusSettler.Lock[] memory locks = new INexusSettler.Lock[](1);
        locks[0] = INexusSettler.Lock({
            token: bytes32(bytes20(address(tokenA))),
            amount: LOCK_AMOUNT
        });
        
        INexusSettler.Fund[] memory funds = new INexusSettler.Fund[](1);
        funds[0] = INexusSettler.Fund({
            recipient: bytes32(bytes20(address(aavePool))),
            token: bytes32(bytes20(address(tokenA))),
            amount: LOCK_AMOUNT
        });
        
        INexusSettler.Action[] memory actions = new INexusSettler.Action[](1);
        bytes memory supplyCallData = abi.encodeWithSelector(
            MockAavePool.supply.selector,
            address(tokenA),
            LOCK_AMOUNT,
            owner,
            uint16(0)
        );
        actions[0] = INexusSettler.Action({
            actionType: INexusSettler.ActionType.SWAP,
            target: Strings.toHexString(uint256(uint160(address(aavePool))), 20),
            callData: supplyCallData,
            value: 0
        });
        
        INexusSettler.Actions memory batch = INexusSettler.Actions({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            settler: bytes32(bytes20(address(nexusSettler))),
            conditions: conditions,
            locks: locks,
            funds: funds,
            actions: actions,
            fees: INexusSettler.Fees(bytes32(0), 0)
        });
        
        INexusSettler.Actions[] memory batches = new INexusSettler.Actions[](1);
        batches[0] = batch;
        
        INexusSettler.Resource[] memory inputs = new INexusSettler.Resource[](0);
        INexusSettler.Resource[] memory outputs = new INexusSettler.Resource[](0);
        
        INexusSettler.Intent memory intent = INexusSettler.Intent({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            batches: batches,
            sender: bytes32(bytes20(owner)),
            recipient: bytes32(bytes20(owner)),
            nonce: 1,
            inputs: inputs,
            outputs: outputs
        });
        
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);
        
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });
        
        vm.prank(owner);
        nexusSettler.open(order);
        
        // Profile NexusSettler
        vm.prank(filler1);
        uint256 gasNexus = gasleft();
        nexusSettler.fill(orderId, originData, "");
        gasNexus = gasNexus - gasleft();
        
        // ============ DIRECT FILL FLOW (Pure Transfers) ============
        address filler2 = makeAddr("filler2_aave");
        
        // Fund owner and filler2
        tokenA.mint(owner, LOCK_AMOUNT);
        tokenA.mint(filler2, LOCK_AMOUNT);
        
        // Profile pure transfers (no contract overhead)
        uint256 gasDirect = gasleft();
        
        // Lock: owner -> escrow
        vm.prank(owner);
        tokenA.transfer(escrow, LOCK_AMOUNT);
        
        // Action: filler2 -> recipient
        vm.prank(filler2);
        tokenA.transfer(recipient1, LOCK_AMOUNT);
        
        gasDirect = gasDirect - gasleft();
        
        // ============ COMPARISON OUTPUT ============
        console2.log("\n=== Gas Comparison (Aave Deposit) ===");
        console2.log("NexusSettler Aave deposit gas:", gasNexus);
        console2.log("Direct Aave deposit gas:", gasDirect);
        console2.log("Overhead:", gasNexus - gasDirect);
        console2.log("gas (", ((gasNexus - gasDirect) * 100) / gasDirect, "%)");
    }

    // ============ Foundry Gas Snapshots ============

    function testGasSnapshot_NexusSettlerFill() public {
        INexusSettler.Intent memory intent = createTestIntent();
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);
        
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });
        
        vm.prank(owner);
        nexusSettler.open(order);
        
        vm.prank(filler);
        nexusSettler.fill(orderId, originData, "");
    }

    function testGasSnapshot_DirectFill() public {
        DirectFillData memory data = createDirectFillData();
        
        vm.prank(filler);
        directFill.directFill(owner, data);
    }

    // ============ Aave Deposit Snapshot Tests ============

    function testGasSnapshot_AaveDeposit_NexusSettler() public {
        // Deploy MockAavePool and aToken
        MockAavePool aavePool = new MockAavePool();
        MockAToken aTokenA = new MockAToken("aToken A", "aTKA");
        aTokenA.setMinter(address(aavePool));
        aavePool.setATokenForAsset(address(tokenA), address(aTokenA));
        
        // Setup tokens and approvals
        vm.startPrank(owner);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();
        
        tokenA.mint(filler, INITIAL_BALANCE);
        vm.startPrank(filler);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();
        
        // Create Intent with supply action
        INexusSettler.Action[] memory conditions = new INexusSettler.Action[](0);
        
        INexusSettler.Lock[] memory locks = new INexusSettler.Lock[](1);
        locks[0] = INexusSettler.Lock({
            token: bytes32(bytes20(address(tokenA))),
            amount: LOCK_AMOUNT
        });
        
        INexusSettler.Fund[] memory funds = new INexusSettler.Fund[](1);
        funds[0] = INexusSettler.Fund({
            recipient: bytes32(bytes20(address(aavePool))),
            token: bytes32(bytes20(address(tokenA))),
            amount: LOCK_AMOUNT
        });
        
        INexusSettler.Action[] memory actions = new INexusSettler.Action[](1);
        bytes memory supplyCallData = abi.encodeWithSelector(
            MockAavePool.supply.selector,
            address(tokenA),
            LOCK_AMOUNT,
            owner,
            uint16(0)
        );
        actions[0] = INexusSettler.Action({
            actionType: INexusSettler.ActionType.SWAP,
            target: Strings.toHexString(uint256(uint160(address(aavePool))), 20),
            callData: supplyCallData,
            value: 0
        });
        
        INexusSettler.Actions memory batch = INexusSettler.Actions({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            settler: bytes32(bytes20(address(nexusSettler))),
            conditions: conditions,
            locks: locks,
            funds: funds,
            actions: actions,
            fees: INexusSettler.Fees(bytes32(0), 0)
        });
        
        INexusSettler.Actions[] memory batches = new INexusSettler.Actions[](1);
        batches[0] = batch;
        
        INexusSettler.Resource[] memory inputs = new INexusSettler.Resource[](0);
        INexusSettler.Resource[] memory outputs = new INexusSettler.Resource[](0);
        
        INexusSettler.Intent memory intent = INexusSettler.Intent({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            batches: batches,
            sender: bytes32(bytes20(owner)),
            recipient: bytes32(bytes20(owner)),
            nonce: 1,
            inputs: inputs,
            outputs: outputs
        });
        
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);
        
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });
        
        vm.prank(owner);
        nexusSettler.open(order);
        
        // Execute fill (no gasleft() - snapshot measures differently)
        vm.prank(filler);
        nexusSettler.fill(orderId, originData, "");
    }

    function testGasSnapshot_AaveDeposit_Direct() public {
        // This test shows the absolute baseline: pure ERC20 transfers without ANY contract overhead
        // No DirectFill contract, no NexusSettler - just direct token transfers
        
        // Fund owner and filler
        tokenA.mint(owner, LOCK_AMOUNT);
        tokenA.mint(filler, LOCK_AMOUNT);
        
        // Execute pure transfers (no contract overhead)
        // Lock: owner -> escrow
        vm.prank(owner);
        tokenA.transfer(escrow, LOCK_AMOUNT);
        
        // Action: filler -> recipient
        vm.prank(filler);
        tokenA.transfer(recipient1, LOCK_AMOUNT);
    }

    // ============ Swap Helper Functions ============

    function createSwapIntent(bool exactOut) internal view returns (INexusSettler.Intent memory) {
        // Create PoolKey with proper token ordering
        address token0 = address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address token1 = address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: SWAP_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Create Swap struct
        UniswapV4Router.Swap memory swap = UniswapV4Router.Swap({
            key: key,
            maxAmountIn: uint128(SWAP_AMOUNT_IN),
            minAmountOut: uint128(SWAP_MIN_AMOUNT_OUT),
            zeroForOne: address(tokenA) == token0, // true if tokenA is currency0
            exactOut: exactOut,
            deadline: block.timestamp + 1 hours,
            destination: recipient1
        });

        // Create Action
        INexusSettler.Action[] memory actions = new INexusSettler.Action[](1);
        actions[0] = INexusSettler.Action({
            actionType: INexusSettler.ActionType.SWAP,
            target: Strings.toHexString(uint256(uint160(address(uniswapV4Router))), 20),
            callData: abi.encode(swap),
            value: 0
        });

        // Create batch
        INexusSettler.Actions memory batch = INexusSettler.Actions({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            settler: bytes32(bytes20(address(nexusSettler))),
            conditions: new INexusSettler.Action[](0),
            locks: new INexusSettler.Lock[](0),
            funds: new INexusSettler.Fund[](0),
            actions: actions,
            fees: INexusSettler.Fees(bytes32(0), 0)
        });

        INexusSettler.Actions[] memory batches = new INexusSettler.Actions[](1);
        batches[0] = batch;

        return INexusSettler.Intent({
            domain: string.concat("eip155:", Strings.toString(block.chainid)),
            batches: batches,
            sender: bytes32(bytes20(owner)),
            recipient: bytes32(bytes20(recipient1)),
            nonce: 1,
            inputs: new INexusSettler.Resource[](0),
            outputs: new INexusSettler.Resource[](0)
        });
    }

    function createSwapDirectFillData(bool /* exactOut */) internal view returns (DirectFillData memory) {
        // Create swap action for DirectFill
        DirectAction[] memory actions = new DirectAction[](1);

        // Encode the swap call for MockV4SwapRouter
        actions[0] = DirectAction({
            target: address(mockV4SwapRouter),
            callData: abi.encodeWithSelector(
                MockV4SwapRouter.executeSwap.selector,
                address(tokenA),
                address(tokenB),
                SWAP_AMOUNT_IN,
                SWAP_MIN_AMOUNT_OUT
            ),
            value: 0
        });

        return DirectFillData({
            conditions: new DirectAction[](0),
            locks: new DirectLock[](0),
            funds: new DirectFund[](0),
            actions: actions
        });
    }

    // ============ Swap Gas Profile Tests ============

    function testGasProfile_SwapExactIn_NexusSettler() public {
        // Setup: Create intent and order
        INexusSettler.Intent memory intent = createSwapIntent(false); // false = exactIn
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);

        // Create order
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });

        // Setup fresh filler
        address swapFiller = makeAddr("swapFiller");
        tokenA.mint(swapFiller, INITIAL_BALANCE);
        vm.startPrank(swapFiller);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // Fund NexusSettler with tokens for the swap
        vm.startPrank(swapFiller);
        tokenA.transfer(address(nexusSettler), SWAP_AMOUNT_IN);
        vm.stopPrank();

        // NexusSettler approves UniswapV4Router
        vm.startPrank(address(nexusSettler));
        tokenA.approve(address(uniswapV4Router), type(uint256).max);
        vm.stopPrank();

        // Open order
        vm.prank(owner);
        nexusSettler.open(order);

        // Profile gas
        vm.prank(swapFiller);
        uint256 gasStart = gasleft();
        nexusSettler.fill(orderId, originData, "");
        uint256 gasUsed = gasStart - gasleft();

        console2.log("=== NexusSettler Swap ExactIn Gas ===");
        console2.log("Gas used:", gasUsed);
    }

    function testGasProfile_SwapExactIn_DirectFill() public {
        // Setup fresh filler
        address swapFillerDirect = makeAddr("swapFillerDirect");
        tokenA.mint(swapFillerDirect, INITIAL_BALANCE);
        vm.startPrank(swapFillerDirect);
        tokenA.approve(address(directFill), type(uint256).max);
        vm.stopPrank();

        // Fund DirectFill with tokens
        vm.startPrank(swapFillerDirect);
        tokenA.transfer(address(directFill), SWAP_AMOUNT_IN);
        vm.stopPrank();

        // DirectFill approves mockV4SwapRouter
        vm.startPrank(address(directFill));
        tokenA.approve(address(mockV4SwapRouter), type(uint256).max);
        vm.stopPrank();

        // Create DirectFillData
        DirectFillData memory data = createSwapDirectFillData(false); // false = exactIn

        // Profile gas
        vm.prank(swapFillerDirect);
        uint256 gasStart = gasleft();
        directFill.directFill(owner, data);
        uint256 gasUsed = gasStart - gasleft();

        console2.log("=== DirectFill Swap ExactIn Gas ===");
        console2.log("Gas used:", gasUsed);
    }

    function testGasProfile_SwapExactOut_NexusSettler() public {
        // Setup: Create intent and order
        INexusSettler.Intent memory intent = createSwapIntent(true); // true = exactOut
        bytes memory originData = abi.encode(intent);
        bytes32 orderId = keccak256(originData);

        // Create order
        IERC7683.OnchainCrossChainOrder memory order = IERC7683.OnchainCrossChainOrder({
            fillDeadline: uint32(block.timestamp + 1 hours),
            orderDataType: keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)"),
            orderData: originData
        });

        // Setup fresh filler
        address swapFillerOut = makeAddr("swapFillerOut");
        tokenA.mint(swapFillerOut, INITIAL_BALANCE);
        vm.startPrank(swapFillerOut);
        tokenA.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // Fund NexusSettler with tokens for the swap
        vm.startPrank(swapFillerOut);
        tokenA.transfer(address(nexusSettler), SWAP_AMOUNT_IN);
        vm.stopPrank();

        // NexusSettler approves UniswapV4Router
        vm.startPrank(address(nexusSettler));
        tokenA.approve(address(uniswapV4Router), type(uint256).max);
        vm.stopPrank();

        // Open order
        vm.prank(owner);
        nexusSettler.open(order);

        // Profile gas
        vm.prank(swapFillerOut);
        uint256 gasStart = gasleft();
        nexusSettler.fill(orderId, originData, "");
        uint256 gasUsed = gasStart - gasleft();

        console2.log("=== NexusSettler Swap ExactOut Gas ===");
        console2.log("Gas used:", gasUsed);
    }

    function testGasProfile_SwapExactOut_DirectFill() public {
        // Setup fresh filler
        address swapFillerDirectOut = makeAddr("swapFillerDirectOut");
        tokenA.mint(swapFillerDirectOut, INITIAL_BALANCE);
        vm.startPrank(swapFillerDirectOut);
        tokenA.approve(address(directFill), type(uint256).max);
        vm.stopPrank();

        // Fund DirectFill with tokens
        vm.startPrank(swapFillerDirectOut);
        tokenA.transfer(address(directFill), SWAP_AMOUNT_IN);
        vm.stopPrank();

        // DirectFill approves mockV4SwapRouter
        vm.startPrank(address(directFill));
        tokenA.approve(address(mockV4SwapRouter), type(uint256).max);
        vm.stopPrank();

        // Create DirectFillData
        DirectFillData memory data = createSwapDirectFillData(true); // true = exactOut

        // Profile gas
        vm.prank(swapFillerDirectOut);
        uint256 gasStart = gasleft();
        directFill.directFill(owner, data);
        uint256 gasUsed = gasStart - gasleft();

        console2.log("=== DirectFill Swap ExactOut Gas ===");
        console2.log("Gas used:", gasUsed);
    }
}
