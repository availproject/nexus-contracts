// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockBridge
/// @notice Mock bridge for testing lock/release functionality
/// @dev Simulates bridge lock/release pattern for cross-chain intents
contract MockBridge {
    using SafeERC20 for IERC20;

    // Track locked tokens per user
    mapping(address => mapping(address => uint256)) public lockedAmounts;
    
    // Track total locked per token
    mapping(address => uint256) public totalLocked;
    
    // Owner (for access control)
    address public owner;

    event TokensLocked(address indexed user, address indexed token, uint256 amount);
    event TokensReleased(address indexed user, address indexed token, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    /// @notice Lock tokens on source chain
    /// @param token Token to lock
    /// @param amount Amount to lock
    /// @param destinationChain Destination chain ID
    function lockTokens(address token, uint256 amount, uint16 destinationChain) external {
        require(amount > 0, "Amount must be greater than 0");
        
        // Transfer tokens from user to bridge
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Track locked amount
        lockedAmounts[msg.sender][token] += amount;
        totalLocked[token] += amount;
        
        emit TokensLocked(msg.sender, token, amount);
    }

    /// @notice Release tokens on destination chain
    /// @param token Token to release
    /// @param amount Amount to release
    /// @param recipient Recipient address
    function releaseTokens(address token, uint256 amount, address recipient) external {
        require(msg.sender == owner, "Only owner can release");
        require(amount > 0, "Amount must be greater than 0");
        require(lockedAmounts[recipient][token] >= amount, "Insufficient locked balance");
        
        // Update balances
        lockedAmounts[recipient][token] -= amount;
        totalLocked[token] -= amount;
        
        // Transfer tokens to recipient
        IERC20(token).safeTransfer(recipient, amount);
        
        emit TokensReleased(recipient, token, amount);
    }

    /// @notice Get locked balance for a user
    /// @param user User address
    /// @param token Token address
    /// @return Locked amount
    function getLockedBalance(address user, address token) external view returns (uint256) {
        return lockedAmounts[user][token];
    }

    /// @notice Get total locked for a token
    /// @param token Token address
    /// @return Total locked amount
    function getTotalLocked(address token) external view returns (uint256) {
        return totalLocked[token];
    }
}