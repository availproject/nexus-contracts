// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockReentrantToken
/// @notice ERC20 token with callback hooks for testing reentrancy protection
/// @dev This token attempts to reenter the calling contract during transfer/transferFrom
contract MockReentrantToken is ERC20 {
    /// @notice Target contract to call during reentrancy attempt
    address public reentrancyTarget;
    
    /// @notice Function signature to call during reentrancy
    bytes public reentrancyCallData;
    
    /// @notice Whether to attempt reentrancy on transfer
    bool public attemptReentrancyOnTransfer;
    
    /// @notice Whether to attempt reentrancy on transferFrom
    bool public attemptReentrancyOnTransferFrom;
    
    /// @notice Emitted when reentrancy is attempted
    event ReentrancyAttempted(address indexed target, bytes data);
    
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /// @notice Mint tokens to an address
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Set the reentrancy target and call data
    /// @param target The contract to call during reentrancy
    /// @param data The function call data
    function setReentrancyTarget(address target, bytes calldata data) external {
        reentrancyTarget = target;
        reentrancyCallData = data;
    }

    /// @notice Enable/disable reentrancy on transfer
    function setAttemptReentrancyOnTransfer(bool enabled) external {
        attemptReentrancyOnTransfer = enabled;
    }

    /// @notice Enable/disable reentrancy on transferFrom
    function setAttemptReentrancyOnTransferFrom(bool enabled) external {
        attemptReentrancyOnTransferFrom = enabled;
    }

    /// @notice Transfer with potential reentrancy attempt
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Perform the transfer first
        bool success = super.transfer(to, amount);
        
        // Attempt reentrancy if enabled
        if (attemptReentrancyOnTransfer && reentrancyTarget != address(0)) {
            emit ReentrancyAttempted(reentrancyTarget, reentrancyCallData);
            (bool reentrancySuccess,) = reentrancyTarget.call(reentrancyCallData);
            // We don't care if the reentrancy succeeds or fails
            // The test will verify that the contract blocks it
            reentrancySuccess; // silence unused variable warning
        }
        
        return success;
    }

    /// @notice TransferFrom with potential reentrancy attempt
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Perform the transfer first
        bool success = super.transferFrom(from, to, amount);
        
        // Attempt reentrancy if enabled
        if (attemptReentrancyOnTransferFrom && reentrancyTarget != address(0)) {
            emit ReentrancyAttempted(reentrancyTarget, reentrancyCallData);
            (bool reentrancySuccess,) = reentrancyTarget.call(reentrancyCallData);
            // We don't care if the reentrancy succeeds or fails
            // The test will verify that the contract blocks it
            reentrancySuccess; // silence unused variable warning
        }
        
        return success;
    }
}
