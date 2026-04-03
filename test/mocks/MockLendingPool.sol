// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockLendingPool
/// @notice Mock lending pool for testing deposit functionality
/// @dev Simulates lending pool that accepts deposits and mints aTokens
contract MockLendingPool {
    using SafeERC20 for IERC20;

    // Track supplied amounts per user per asset
    mapping(address => mapping(address => uint256)) public supplied;
    
    // Mapping from underlying asset to aToken
    mapping(address => address) public aTokenAddresses;

    event Supplied(address indexed user, address indexed asset, uint256 amount);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount);

    /// @notice Supply assets to the lending pool
    /// @param asset Underlying asset address
    /// @param amount Amount to supply
    function supply(address asset, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        
        // Transfer tokens from user
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update tracking
        supplied[msg.sender][asset] += amount;
        
        // Mint aTokens to user (if aToken exists for this asset)
        address aToken = aTokenAddresses[asset];
        if (aToken != address(0)) {
            // Use interface to call mint function
            (bool success,) = aToken.call(abi.encodeWithSignature("mint(address,uint256)", msg.sender, amount));
            require(success, "Mint failed");
        }
        
        emit Supplied(msg.sender, asset, amount);
    }

    /// @notice Withdraw assets from the lending pool
    /// @param asset Underlying asset address
    /// @param amount Amount to withdraw
    function withdraw(address asset, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(supplied[msg.sender][asset] >= amount, "Insufficient balance");
        
        // Burn aTokens if exists
        address aToken = aTokenAddresses[asset];
        if (aToken != address(0)) {
            // Use interface to call burn function
            (bool success,) = aToken.call(abi.encodeWithSignature("burn(address,uint256)", msg.sender, amount));
            require(success, "Burn failed");
        }
        
        // Update tracking
        supplied[msg.sender][asset] -= amount;
        
        // Transfer underlying to user
        IERC20(asset).safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, asset, amount);
    }

    /// @notice Set the aToken address for an underlying asset
    /// @param asset Underlying asset address
    /// @param aToken aToken address
    function setATokenAddress(address asset, address aToken) external {
        aTokenAddresses[asset] = aToken;
    }

    /// @notice Get supplied balance for a user
    /// @param user User address
    /// @param asset Underlying asset address
    /// @return Supplied amount
    function getSuppliedBalance(address user, address asset) external view returns (uint256) {
        return supplied[user][asset];
    }
}