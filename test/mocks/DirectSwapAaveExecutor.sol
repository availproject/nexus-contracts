// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockV4SwapRouter} from "./MockV4SwapRouter.sol";
import {MockAavePool} from "./MockAavePool.sol";
import {MockPoolManager} from "./MockPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";

/// @title DirectSwapAaveExecutor
/// @notice Execute swap then deposit to Aave in a single transaction
/// @dev Minimal implementation for DirectFill comparison
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

    /**
     * @notice Deposit only: pull tokens from caller, approve, deposit to Aave
     * @dev Same flow as DAG (pull → approve → supply) without swap
     */
    function depositOnly(
        address token,
        uint256 amount,
        address beneficiary
    ) external returns (bool success) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(address(AAVE_POOL), amount);
        AAVE_POOL.supply(token, amount, beneficiary, 0);
        return true;
    }

    /**
     * @notice Two rounds of (pull → approve → swap → approve → supply) = 10 operations
     * @dev Calls poolManager directly (not via router) to match DAG call targets exactly
     */
    function doubleSwapDeposit(
        address poolManager,
        PoolKey calldata key,
        bool zeroForOne,
        address tokenIn,
        address tokenOut,
        uint256 swapAmountPerRound,
        uint256 depositAmountPerRound,
        uint256 minAmountOut,
        address beneficiary
    ) external returns (bool success) {
        // Round 1: pull → approve PM → swap → approve Aave → supply
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), swapAmountPerRound);
        IERC20(tokenIn).approve(poolManager, swapAmountPerRound);
        MockPoolManager(poolManager).swap(key, zeroForOne, swapAmountPerRound, minAmountOut);
        IERC20(tokenOut).approve(address(AAVE_POOL), depositAmountPerRound);
        AAVE_POOL.supply(tokenOut, depositAmountPerRound, beneficiary, 0);

        // Round 2: pull → approve PM → swap → approve Aave → supply
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), swapAmountPerRound);
        IERC20(tokenIn).approve(poolManager, swapAmountPerRound);
        MockPoolManager(poolManager).swap(key, zeroForOne, swapAmountPerRound, minAmountOut);
        IERC20(tokenOut).approve(address(AAVE_POOL), depositAmountPerRound);
        AAVE_POOL.supply(tokenOut, depositAmountPerRound, beneficiary, 0);

        return true;
    }
}
