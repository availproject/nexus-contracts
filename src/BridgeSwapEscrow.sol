// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/// @title BridgeSwapEscrow
/// @notice Escrow contract for multi-step bridge + swap + deposit flows
/// @dev Uses bitmap pattern for step tracking and timeouts for refund eligibility
contract BridgeSwapEscrow is ReentrancyGuardTransient, AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Role identifier for the settler contract
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    /// @notice Default timeout period for intents (1 day)
    uint256 public constant DEFAULT_TIMEOUT = 1 days;

    /// @notice Intent structure containing user deposit details
    struct Intent {
        address user;
        address token;
        uint256 amount;
        uint256 deadline;
        bytes32 intentId;
    }

    /// @notice Intent status tracking completion state
    struct IntentStatus {
        bool deposited;
        bool refunded;
        bool completed;
        uint256 stepBitmap;
    }

    /// @notice Mapping from intent ID to intent details
    mapping(bytes32 => Intent) public intents;

    /// @notice Mapping from intent ID to intent status
    mapping(bytes32 => IntentStatus) public intentStatus;

    /// @notice Emitted when user deposits an intent
    event IntentDeposited(bytes32 indexed intentId, address indexed user, address token, uint256 amount);

    /// @notice Emitted when a step is released to target
    event StepReleased(bytes32 indexed intentId, uint8 indexed step, address indexed target, uint256 amount);

    /// @notice Emitted when intent is refunded via timeout
    event IntentRefunded(bytes32 indexed intentId, address indexed user, address token, uint256 amount);

    /// @notice Constructor
    /// @param nexusSettler Address of the NexusSettler contract
    constructor(address nexusSettler) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SETTLER_ROLE, nexusSettler);
    }

    /// @notice Deposits user funds into escrow for bridge + swap + deposit flow
    /// @param intent The intent details
    function depositIntent(Intent calldata intent) external nonReentrant {
        // ===== CHECKS =====
        // Verify amount is positive
        if (intent.amount == 0) revert("Amount must be greater than zero");
        
        // Calculate intent ID
        bytes32 intentId = keccak256(abi.encode(intent));
        
        // Verify intent not already deposited
        if (intentStatus[intentId].deposited) revert("Intent already deposited");
        
        // ===== EFFECTS =====
        // Store intent with deadline
        intents[intentId] = Intent({
            user: intent.user,
            token: intent.token,
            amount: intent.amount,
            deadline: block.timestamp + DEFAULT_TIMEOUT,
            intentId: intentId
        });
        
        // Set status as deposited
        intentStatus[intentId] = IntentStatus({
            deposited: true,
            refunded: false,
            completed: false,
            stepBitmap: 0
        });
        
        // ===== INTERACTIONS =====
        // Transfer tokens from user to escrow
        IERC20(intent.token).safeTransferFrom(msg.sender, address(this), intent.amount);
        
        // Emit event
        emit IntentDeposited(intentId, msg.sender, intent.token, intent.amount);
    }

    /// @notice Releases funds after step completion (called by settler)
    /// @param intentId The intent identifier
    /// @param step The step number completed
    /// @param target Address to receive funds
    /// @param amount Amount to release
    function releaseAfterStep(
        bytes32 intentId,
        uint8 step,
        address target,
        uint256 amount
    ) external onlyRole(SETTLER_ROLE) nonReentrant {
        // ===== CHECKS =====
        // Verify intent exists
        if (!intentStatus[intentId].deposited) revert("Intent not deposited");
        
        // Verify not refunded
        if (intentStatus[intentId].refunded) revert("Intent already refunded");
        
        // Verify not completed
        if (intentStatus[intentId].completed) revert("Intent already completed");
        
        // Verify deadline not passed
        if (block.timestamp > intents[intentId].deadline) revert("Deadline passed");
        
        // Verify step not already complete
        if ((intentStatus[intentId].stepBitmap & (1 << step)) != 0) revert("Step already complete");
        
        // Verify amount is positive
        if (amount == 0) revert("Amount must be greater than zero");
        
        // Verify target is valid
        if (target == address(0)) revert("Invalid target address");
        
        // ===== EFFECTS =====
        // Update bitmap to mark step as complete
        intentStatus[intentId].stepBitmap |= (1 << step);
        
        // ===== INTERACTIONS =====
        // Transfer tokens to target
        IERC20(intents[intentId].token).safeTransfer(target, amount);
        
        // Emit event
        emit StepReleased(intentId, step, target, amount);
    }

    /// @notice Claims refund after timeout deadline passes
    /// @param intentId The intent identifier
    function claimTimeoutRefund(bytes32 intentId) external nonReentrant {
        // TODO: Implement timeout refund logic
    }

    /// @notice Retrieves full intent details
    /// @param intentId The intent identifier
    /// @return Intent struct with all details
    function getIntent(bytes32 intentId) external view returns (Intent memory) {
        return intents[intentId];
    }

    /// @notice Checks if a specific step is complete
    /// @param intentId The intent identifier
    /// @param step The step number to check
    /// @return True if step is complete
    function isStepComplete(bytes32 intentId, uint8 step) external view returns (bool) {
        return (intentStatus[intentId].stepBitmap & (1 << step)) != 0;
    }
}
