// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/v4-core/src/types/PoolKey.sol";
import "lib/v4-core/src/types/Currency.sol";
import "../mocks/MockPoolManager.sol";
import "../mocks/MockUniversalRouter.sol";
import "../mocks/MockV4SwapRouter.sol";
import "../mocks/MockPermit2.sol";

/// @title MockERC20 for testing
contract TestERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title MockV4ContractsTest
/// @notice Unit tests for mock V4 contracts
contract MockV4ContractsTest is Test {
    MockPoolManager public poolManager;
    MockUniversalRouter public universalRouter;
    MockV4SwapRouter public v4SwapRouter;
    MockPermit2 public permit2;

    TestERC20 public token0;
    TestERC20 public token1;

    address public user;
    address public liquidityProvider;

    // Test constants
    uint256 constant INITIAL_LIQUIDITY = 1000000e18; // 1M tokens each
    uint256 constant SWAP_AMOUNT = 1000e18; // 1000 tokens
    // Expected output for 1000 tokens in with 0.3% fee and 1M reserves
    // amountOut = (1000 * 9970 * 1000000) / (10000 * 1000000 + 1000 * 9970) ≈ 996 tokens
    uint256 constant EXPECTED_OUTPUT = 996e18; // ~996 tokens (0.3% fee)

    function setUp() public {
        // Setup addresses
        user = makeAddr("user");
        liquidityProvider = makeAddr("liquidityProvider");

        // Deploy tokens
        TestERC20 tokenA = new TestERC20("Token A", "TKA");
        TestERC20 tokenB = new TestERC20("Token B", "TKB");

        // Sort by address (currency0 < currency1)
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }

        // Deploy contracts
        poolManager = new MockPoolManager();
        permit2 = new MockPermit2();
        universalRouter = new MockUniversalRouter(address(poolManager), address(permit2));
        v4SwapRouter = new MockV4SwapRouter(address(poolManager));

        // Mint tokens to user and liquidity provider
        token0.mint(user, INITIAL_LIQUIDITY * 10);
        token1.mint(user, INITIAL_LIQUIDITY * 10);
        token0.mint(liquidityProvider, INITIAL_LIQUIDITY);
        token1.mint(liquidityProvider, INITIAL_LIQUIDITY);

        // Setup approvals
        vm.startPrank(liquidityProvider);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        token0.approve(address(universalRouter), type(uint256).max);
        token1.approve(address(universalRouter), type(uint256).max);
        token0.approve(address(v4SwapRouter), type(uint256).max);
        token1.approve(address(v4SwapRouter), type(uint256).max);
        vm.stopPrank();

        // Initialize pool with liquidity
        PoolKey memory key = _createPoolKey();
        vm.prank(liquidityProvider);
        poolManager.initializePool(key, INITIAL_LIQUIDITY, INITIAL_LIQUIDITY);
    }

    // ============ MockPoolManager Tests ============

    function test_MockPoolManager_Initialize() public {
        // Deploy new tokens and pool manager for fresh test
        TestERC20 newToken0 = new TestERC20("New Token 0", "NTK0");
        TestERC20 newToken1 = new TestERC20("New Token 1", "NTK1");
        MockPoolManager newPoolManager = new MockPoolManager();

        // Ensure proper ordering
        TestERC20 sorted0 = address(newToken0) < address(newToken1) ? newToken0 : newToken1;
        TestERC20 sorted1 = address(newToken0) < address(newToken1) ? newToken1 : newToken0;

        // Mint and approve
        sorted0.mint(user, INITIAL_LIQUIDITY);
        sorted1.mint(user, INITIAL_LIQUIDITY);
        vm.startPrank(user);
        sorted0.approve(address(newPoolManager), type(uint256).max);
        sorted1.approve(address(newPoolManager), type(uint256).max);

        // Create pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(sorted0)),
            currency1: Currency.wrap(address(sorted1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Initialize pool
        newPoolManager.initializePool(key, INITIAL_LIQUIDITY, INITIAL_LIQUIDITY);

        // Verify reserves
        bytes32 poolId = newPoolManager.getPoolId(key);
        (uint256 reserve0, uint256 reserve1) = newPoolManager.getReserves(poolId);
        assertEq(reserve0, INITIAL_LIQUIDITY, "Reserve0 mismatch");
        assertEq(reserve1, INITIAL_LIQUIDITY, "Reserve1 mismatch");
        assertTrue(newPoolManager.poolExists(poolId), "Pool should exist");
    }

    function test_MockPoolManager_SwapExactIn() public {
        PoolKey memory key = _createPoolKey();

        uint256 userBalanceBefore0 = token0.balanceOf(user);
        uint256 userBalanceBefore1 = token1.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = poolManager.swap(key, true, SWAP_AMOUNT, EXPECTED_OUTPUT - 1e18);

        uint256 userBalanceAfter0 = token0.balanceOf(user);
        uint256 userBalanceAfter1 = token1.balanceOf(user);

        // Verify balances changed correctly
        assertEq(userBalanceBefore0 - userBalanceAfter0, SWAP_AMOUNT, "Input amount mismatch");
        assertEq(userBalanceAfter1 - userBalanceBefore1, amountOut, "Output amount mismatch");

        // Verify output is approximately correct (0.3% fee)
        // Allow 1% tolerance for rounding
        assertApproxEqAbs(amountOut, EXPECTED_OUTPUT, EXPECTED_OUTPUT / 100, "Output amount not as expected");

        console2.log("Swap: 1000 tokens in ->", amountOut / 1e18, "tokens out");
    }

    function test_MockPoolManager_SwapReverse() public {
        PoolKey memory key = _createPoolKey();

        // Swap token1 for token0
        vm.prank(user);
        uint256 amountOut = poolManager.swap(key, false, SWAP_AMOUNT, EXPECTED_OUTPUT - 1e18);

        // Allow 1% tolerance for rounding
        assertApproxEqAbs(amountOut, EXPECTED_OUTPUT, EXPECTED_OUTPUT / 100, "Output amount not as expected");
    }

    function test_MockPoolManager_RevertIf_PoolDoesNotExist() public {
        // Create a new pool key that doesn't exist
        TestERC20 newToken = new TestERC20("New Token", "NTK");
        PoolKey memory fakeKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(newToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(user);
        vm.expectRevert("Pool does not exist");
        poolManager.swap(fakeKey, true, SWAP_AMOUNT, 0);
    }

    function test_MockPoolManager_RevertIf_InsufficientOutput() public {
        PoolKey memory key = _createPoolKey();

        vm.prank(user);
        vm.expectRevert("Insufficient output amount");
        poolManager.swap(key, true, SWAP_AMOUNT, EXPECTED_OUTPUT + 100e18);
    }

    // ============ MockUniversalRouter Tests ============

    function test_MockUniversalRouter_V4SwapExactIn() public {
        // Create swap params
        PoolKey memory key = _createPoolKey();

        // Encode actions
        bytes memory actions = abi.encodePacked(
            uint8(0x06), // SWAP_EXACT_IN_SINGLE
            uint8(0x0c), // SETTLE_ALL
            uint8(0x0f) // TAKE_ALL
        );

        // Encode params
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            true, // zeroForOne
            SWAP_AMOUNT,
            EXPECTED_OUTPUT - 1e18, // minAmountOut
            bytes("") // hookData
        );
        params[1] = abi.encode(address(token0), SWAP_AMOUNT);
        params[2] = abi.encode(address(token1), EXPECTED_OUTPUT - 1e18);

        // Encode input
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Encode commands
        bytes memory commands = abi.encodePacked(uint8(0x10)); // V4_SWAP

        uint256 balanceBefore0 = token0.balanceOf(user);
        uint256 balanceBefore1 = token1.balanceOf(user);

        vm.prank(user);
        universalRouter.execute(commands, inputs, block.timestamp + 1 hours);

        uint256 balanceAfter0 = token0.balanceOf(user);
        uint256 balanceAfter1 = token1.balanceOf(user);

        // Verify swap occurred
        assertEq(balanceBefore0 - balanceAfter0, SWAP_AMOUNT, "Input not transferred");
        assertGt(balanceAfter1 - balanceBefore1, 0, "Output not received");

        console2.log("UniversalRouter V4_SWAP: token0 -> token1");
    }

    function test_MockUniversalRouter_RevertIf_Expired() public {
        bytes memory commands = abi.encodePacked(uint8(0x10));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(bytes(""), new bytes[](0));

        vm.prank(user);
        vm.expectRevert("Transaction expired");
        universalRouter.execute(commands, inputs, block.timestamp - 1);
    }

    function test_MockUniversalRouter_RevertIf_UnsupportedCommand() public {
        bytes memory commands = abi.encodePacked(uint8(0x00)); // V3_SWAP_EXACT_IN
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(bytes(""), new bytes[](0));

        vm.prank(user);
        vm.expectRevert("Unsupported command");
        universalRouter.execute(commands, inputs, block.timestamp + 1 hours);
    }

    // ============ MockV4SwapRouter Tests ============

    function test_MockV4SwapRouter_DirectSwap() public {
        uint256 balanceBefore0 = token0.balanceOf(user);
        uint256 balanceBefore1 = token1.balanceOf(user);

        vm.prank(user);
        uint256 amountOut =
            v4SwapRouter.executeSwap(address(token0), address(token1), SWAP_AMOUNT, EXPECTED_OUTPUT - 1e18);

        uint256 balanceAfter0 = token0.balanceOf(user);
        uint256 balanceAfter1 = token1.balanceOf(user);

        // Verify swap occurred
        assertEq(balanceBefore0 - balanceAfter0, SWAP_AMOUNT, "Input not transferred");
        assertEq(balanceAfter1 - balanceBefore1, amountOut, "Output not received");
        // Allow 1% tolerance for rounding
        assertApproxEqAbs(amountOut, EXPECTED_OUTPUT, EXPECTED_OUTPUT / 100, "Output amount not as expected");

        console2.log("V4SwapRouter direct swap: 1000 ->", amountOut / 1e18);
    }

    function test_MockV4SwapRouter_SwapWithKey() public {
        PoolKey memory key = _createPoolKey();

        uint256 balanceBefore0 = token0.balanceOf(user);
        uint256 balanceBefore1 = token1.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = v4SwapRouter.executeSwapWithKey(
            key,
            true, // zeroForOne
            SWAP_AMOUNT,
            EXPECTED_OUTPUT - 1e18
        );

        uint256 balanceAfter0 = token0.balanceOf(user);
        uint256 balanceAfter1 = token1.balanceOf(user);

        // Verify swap occurred
        assertEq(balanceBefore0 - balanceAfter0, SWAP_AMOUNT, "Input not transferred");
        assertEq(balanceAfter1 - balanceBefore1, amountOut, "Output not received");
    }

    // ============ Gas Profiling Tests ============

    function testGas_MockPoolManager_Swap() public {
        PoolKey memory key = _createPoolKey();

        vm.prank(user);
        uint256 gasStart = gasleft();
        poolManager.swap(key, true, SWAP_AMOUNT, EXPECTED_OUTPUT - 1e18);
        uint256 gasUsed = gasStart - gasleft();

        console2.log("MockPoolManager.swap() gas:", gasUsed);
    }

    function testGas_MockUniversalRouter_Execute() public {
        PoolKey memory key = _createPoolKey();

        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, true, SWAP_AMOUNT, EXPECTED_OUTPUT - 1e18, bytes(""));
        params[1] = abi.encode(address(token0), SWAP_AMOUNT);
        params[2] = abi.encode(address(token1), EXPECTED_OUTPUT - 1e18);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        bytes memory commands = abi.encodePacked(uint8(0x10));

        vm.prank(user);
        uint256 gasStart = gasleft();
        universalRouter.execute(commands, inputs, block.timestamp + 1 hours);
        uint256 gasUsed = gasStart - gasleft();

        console2.log("MockUniversalRouter.execute() gas:", gasUsed);
    }

    function testGas_MockV4SwapRouter_ExecuteSwap() public {
        vm.prank(user);
        uint256 gasStart = gasleft();
        v4SwapRouter.executeSwap(address(token0), address(token1), SWAP_AMOUNT, EXPECTED_OUTPUT - 1e18);
        uint256 gasUsed = gasStart - gasleft();

        console2.log("MockV4SwapRouter.executeSwap() gas:", gasUsed);
    }

    // ============ Helper Functions ============

    function _createPoolKey() internal view returns (PoolKey memory key) {
        // Ensure proper ordering (currency0 < currency1)
        address sorted0 = address(token0) < address(token1) ? address(token0) : address(token1);
        address sorted1 = address(token0) < address(token1) ? address(token1) : address(token0);

        key = PoolKey({
            currency0: Currency.wrap(sorted0),
            currency1: Currency.wrap(sorted1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}
