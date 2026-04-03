// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockSwapRouter
/// @notice Mock swap router for testing swap functionality
/// @dev Simulates DEX swap without needing actual pool infrastructure
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    // Simulated exchange rate (1 tokenIn = 99.5% tokenOut for testing)
    uint256 public constant EXCHANGE_RATE = 9950; // 99.5% (in basis points)
    uint256 public constant RATE_DENOMINATOR = 10000;

    // Track swaps for testing
    mapping(address => mapping(address => uint256)) public swapAmounts;

    event SwapExecuted(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Execute a swap
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param amountIn Input amount
    /// @param minAmountOut Minimum output amount (slippage protection)
    /// @return amountOut Output amount
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Amount in must be greater than 0");
        
        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Calculate output amount (with simulated slippage)
        amountOut = (amountIn * EXCHANGE_RATE) / RATE_DENOMINATOR;
        
        require(amountOut >= minAmountOut, "Insufficient output amount");
        
        // Transfer output tokens to caller
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        
        // Track for testing
        swapAmounts[tokenIn][tokenOut] += amountIn;
        
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
        
        return amountOut;
    }

    /// @notice Get the simulated exchange rate
    /// @return The exchange rate (basis points)
    function getExchangeRate() external pure returns (uint256) {
        return EXCHANGE_RATE;
    }
}