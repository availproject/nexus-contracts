// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockPoolManager
/// @notice Simulates V4 pool swap math with constant product formula (x*y=k)
/// @dev Minimal implementation for benchmarking NexusSettler swap flow
contract MockPoolManager {
    using SafeERC20 for IERC20;

    // Pool fee in basis points (0.3% = 30 basis points)
    // Note: Uniswap V4 uses ppm (parts per million), so 3000 = 0.3%
    // For the formula, we use basis points: 30 = 0.3%
    uint24 public constant DEFAULT_FEE_BP = 30; // 0.3% in basis points

    // Track pool reserves for constant product formula
    // poolId => reserve0
    mapping(bytes32 => uint256) public reserve0;
    // poolId => reserve1
    mapping(bytes32 => uint256) public reserve1;

    // Track pool existence
    mapping(bytes32 => bool) public poolExists;

    event Swap(
        bytes32 indexed poolId,
        address indexed sender,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    event PoolInitialized(
        bytes32 indexed poolId,
        address currency0,
        address currency1,
        uint256 reserve0Amount,
        uint256 reserve1Amount
    );

    /// @notice Initialize a pool with initial reserves
    /// @param key The pool key containing currency pair
    /// @param amount0 Initial reserve amount for currency0
    /// @param amount1 Initial reserve amount for currency1
    function initializePool(
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1
    ) external {
        bytes32 poolId = getPoolId(key);
        require(!poolExists[poolId], "Pool already exists");

        // Transfer initial liquidity from caller
        IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(
            msg.sender,
            address(this),
            amount0
        );
        IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(
            msg.sender,
            address(this),
            amount1
        );

        reserve0[poolId] = amount0;
        reserve1[poolId] = amount1;
        poolExists[poolId] = true;

        emit PoolInitialized(
            poolId,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            amount0,
            amount1
        );
    }

    /// @notice Execute a swap using constant product formula (x*y=k)
    /// @param key The pool key
    /// @param zeroForOne Direction of swap (true = sell currency0 for currency1)
    /// @param amountIn Input amount
    /// @param minAmountOut Minimum output amount (slippage protection)
    /// @return amountOut Output amount
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        bytes32 poolId = getPoolId(key);
        require(poolExists[poolId], "Pool does not exist");

        // Get current reserves
        uint256 reserveIn = zeroForOne ? reserve0[poolId] : reserve1[poolId];
        uint256 reserveOut = zeroForOne ? reserve1[poolId] : reserve0[poolId];

        // Calculate output using constant product formula with fee
        // For 0.3% fee: amountOut = (amountIn * 997 * reserveOut) / (1000 * reserveIn + amountIn * 997)
        // Using basis points: amountOut = (amountIn * (10000 - fee) * reserveOut) / (10000 * reserveIn + amountIn * (10000 - fee))
        uint256 amountInWithFee = amountIn * (10000 - DEFAULT_FEE_BP);
        amountOut = (amountInWithFee * reserveOut) /
            (10000 * reserveIn + amountInWithFee);

        require(amountOut >= minAmountOut, "Insufficient output amount");
        require(amountOut > 0, "Zero output");

        // Update reserves
        if (zeroForOne) {
            reserve0[poolId] += amountIn;
            reserve1[poolId] -= amountOut;
        } else {
            reserve1[poolId] += amountIn;
            reserve0[poolId] -= amountOut;
        }

        // Transfer tokens
        address tokenIn = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        address tokenOut = zeroForOne
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit Swap(poolId, msg.sender, zeroForOne, amountIn, amountOut);

        return amountOut;
    }

    /// @notice Get pool ID from pool key
    /// @param key The pool key
    /// @return poolId The pool identifier
    function getPoolId(PoolKey calldata key) public pure returns (bytes32 poolId) {
        poolId = keccak256(
            abi.encode(
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1),
                key.fee,
                key.tickSpacing,
                address(key.hooks)
            )
        );
    }

    /// @notice Get reserves for a pool
    /// @param poolId The pool identifier
    /// @return _reserve0 Reserve of currency0
    /// @return _reserve1 Reserve of currency1
    function getReserves(
        bytes32 poolId
    ) external view returns (uint256 _reserve0, uint256 _reserve1) {
        return (reserve0[poolId], reserve1[poolId]);
    }
}
