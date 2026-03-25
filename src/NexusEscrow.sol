// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {INexusEscrow} from "./interfaces/INexusEscrow.sol";

/// @title NexusEscrow
/// @notice A simple escrow contract for holding tokens during cross-chain settlements
/// @dev Uses ReentrancyGuardTransient to prevent reentrancy attacks on token transfers
contract NexusEscrow is INexusEscrow, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Settlement contract authorized to initiate transfers
    address public settler;

    /// @notice Contract owner authorized to update settler
    address public immutable owner;

    /// @notice Thrown when an unauthorized caller attempts settlement
    error UnauthorizedSettler();

    /// @notice Thrown when an unauthorized caller attempts to update settler
    error UnauthorizedOwner();

    /// @notice Thrown when attempting to set invalid address
    error InvalidAddress();

    /// @notice Emitted when settler is updated
    event SettlerUpdated(address indexed newSettler);

    constructor(address _settler) {
        if (_settler == address(0)) revert InvalidAddress();
        settler = _settler;
        owner = msg.sender;
    }

    /// @notice Modifier to restrict function access to contract owner only
    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner();
        _;
    }

    /// @notice Modifier to restrict function access to authorized settler only
    modifier onlySettler() {
        if (msg.sender != settler) revert UnauthorizedSettler();
        _;
    }

    /// @notice Updates the authorized settler address
    /// @dev Can only be called by the contract owner
    /// @param newSettler The new settler contract address
    function updateSettler(address newSettler) external onlyOwner {
        if (newSettler == address(0)) revert InvalidAddress();
        settler = newSettler;
        emit SettlerUpdated(newSettler);
    }

    /// @notice Settles multiple token transfers to specified recipients
    /// @dev Protected against reentrancy. Uses checks-effects-interactions pattern.
    /// @param settlements Array of settlement instructions containing token, recipient, and amount
    function settle(Settlement[] calldata settlements) external onlySettler nonReentrant {
        uint256 i;
        for (i = 0; i < settlements.length;) {
            Settlement memory settlement = settlements[i];
            IERC20 token = IERC20(address(bytes20(settlement.token)));
            address recipient = address(bytes20(settlement.recipient));

            // Effects: Perform the transfer (external call is the interaction)
            token.safeTransfer(recipient, settlement.amount);

            unchecked {
                ++i;
            }
        }
    }
}
