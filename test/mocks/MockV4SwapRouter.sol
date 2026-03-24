// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {MockPoolManager} from "./MockPoolManager.sol";

/// @title MockV4SwapRouter
/// @notice Direct swap execution for DirectFill comparison
/// @dev Minimal implementation without NexusSettler overhead
contract MockV4SwapRouter {
    using SafeERC20 for IERC20;

    MockPoolManager public immutable POOL_MANAGER;

    event DirectSwapExecuted(
        address indexed sender, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );

    constructor(address poolManager) {
        POOL_MANAGER = MockPoolManager(poolManager);
    }

    /// @notice Execute a direct swap without NexusSettler overhead
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Input amount
    /// @param minAmountOut Minimum output amount
    /// @return amountOut Output amount
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve pool manager
        IERC20(tokenIn).forceApprove(address(POOL_MANAGER), amountIn);

        // Create a minimal pool key for the swap
        // Note: In real usage, the pool key would be passed or derived
        // For benchmarking, we assume the pool exists with sorted currencies
        PoolKey memory key = _createPoolKey(tokenIn, tokenOut);

        // Determine swap direction based on token ordering
        bool zeroForOne = tokenIn < tokenOut;

        // Execute swap
        amountOut = POOL_MANAGER.swap(key, zeroForOne, amountIn, minAmountOut);

        // Transfer output to caller
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit DirectSwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);

        return amountOut;
    }

    /// @notice Execute swap with full pool key (for more control)
    /// @param key Pool key
    /// @param zeroForOne Swap direction
    /// @param amountIn Input amount
    /// @param minAmountOut Minimum output amount
    /// @return amountOut Output amount
    function executeSwapWithKey(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        address tokenIn = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address tokenOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve pool manager
        IERC20(tokenIn).forceApprove(address(POOL_MANAGER), amountIn);

        // Execute swap
        amountOut = POOL_MANAGER.swap(key, zeroForOne, amountIn, minAmountOut);

        // Transfer output to caller
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit DirectSwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);

        return amountOut;
    }

    /// @notice Create a minimal pool key from token pair
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @return key Pool key with sorted currencies
    function _createPoolKey(address tokenA, address tokenB) internal pure returns (PoolKey memory key) {
        // Sort currencies (currency0 < currency1)
        if (tokenA < tokenB) {
            key.currency0 = Currency.wrap(tokenA);
            key.currency1 = Currency.wrap(tokenB);
        } else {
            key.currency0 = Currency.wrap(tokenB);
            key.currency1 = Currency.wrap(tokenA);
        }
        // Default fee and tick spacing
        key.fee = 3000; // 0.3%
        key.tickSpacing = 60;
        // No hooks
        key.hooks = IHooks(address(0));
    }
}
