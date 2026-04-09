// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";

/// @title AvailEscrow
/// @author Rachit Anand Srivastava ( @privacy_prophet )
/// @notice Upgradeable escrow contract for Avail swap settlement on Base.
///         Holds user input assets during swap execution, releases output assets
///         to users on confirmed settlement, and returns input assets to the solver.
contract AvailEscrow is Initializable, UUPSUpgradeable, ReentrancyGuardTransient, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────

    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 public constant MIN_GLOBAL_UNLOCK_TIMEOUT = 30 minutes;
    uint256 public constant MAX_GLOBAL_UNLOCK_TIMEOUT = 24 hours;

    // ──────────────────────────────────────────────────────────────────────
    // Enums
    // ──────────────────────────────────────────────────────────────────────

    enum IntentStatus {
        EMPTY,
        DEPOSITED,
        SETTLED,
        UNLOCKED
    }

    enum UnlockReason {
        SOLVER_CANCELLED,
        GLOBAL_TIMEOUT,
        DEADLINE_EXPIRED
    }

    // ──────────────────────────────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────────────────────────────

    struct SwapIntent {
        bytes32 intentId;
        address user;
        IntentStatus status;
        uint48 depositTimestamp;
        address solver;
        uint48 deadline;
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 amountOutMin;
    }

    // ──────────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────────

    mapping(bytes32 => SwapIntent) public intents;
    mapping(address => bool) public registeredSolvers;
    mapping(address => bool) public supportedAssets;

    uint256 public globalUnlockTimeout;

    /// @notice Storage gap for upgradeability
    /// @dev Allows adding new state variables in future upgrades without breaking storage layout
    uint256[50] private __gap;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event IntentDeposited(
        bytes32 indexed intentId,
        address indexed user,
        address indexed solver,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        uint48 deadline
    );

    event IntentSettled(
        bytes32 indexed intentId,
        address indexed user,
        address indexed solver,
        address tokenOut,
        uint256 amountOut
    );

    event IntentUnlocked(
        bytes32 indexed intentId, address indexed user, address tokenIn, uint256 amountIn, UnlockReason reason
    );

    event SolverRegistered(address indexed solver);
    event SolverDeregistered(address indexed solver);
    event AssetAdded(address indexed asset);
    event AssetRemoved(address indexed asset);
    event GlobalUnlockTimeoutUpdated(uint256 newTimeout);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error Unauthorized();
    error IntentAlreadyExists();
    error SameAsset();
    error ZeroAmount();
    error DeadlineInPast();
    error InvalidMsgValue();
    error IntentNotDeposited();
    error NotDesignatedSolver();
    error DeadlineExpired();
    error SlippageExceeded();
    error UnlockNotReady();
    error SolverAlreadyRegistered();
    error SolverNotFound();
    error AssetAlreadySupported();
    error AssetNotFound();
    error ZeroAddress();
    error TimeoutOutOfRange();
    error EthTransferFailed();
    error PermitNotAllowedForEth();
    error DeadlineOverflow();

    // ──────────────────────────────────────────────────────────────────────
    // Initializer
    // ──────────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        uint256 _globalUnlockTimeout
    ) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        if (_globalUnlockTimeout < MIN_GLOBAL_UNLOCK_TIMEOUT || _globalUnlockTimeout > MAX_GLOBAL_UNLOCK_TIMEOUT) {
            revert TimeoutOutOfRange();
        }

        __Ownable_init(_owner);
        globalUnlockTimeout = _globalUnlockTimeout;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core: deposit
    // ──────────────────────────────────────────────────────────────────────

    function deposit(
        bytes32 intentId,
        address solver,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        uint256 deadline,
        bytes calldata permit
    ) external payable nonReentrant {
        if (intents[intentId].status != IntentStatus.EMPTY) revert IntentAlreadyExists();
        if (!registeredSolvers[solver]) revert SolverNotFound();
        if (!supportedAssets[tokenIn]) revert AssetNotFound();
        if (!supportedAssets[tokenOut]) revert AssetNotFound();
        if (tokenIn == tokenOut) revert SameAsset();
        if (amountIn == 0) revert ZeroAmount();
        if (amountOutMin == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert DeadlineInPast();
        if (deadline > type(uint48).max) revert DeadlineOverflow();

        if (tokenIn == ETH_ADDRESS) {
            if (msg.value != amountIn) revert InvalidMsgValue();
            if (permit.length > 0) revert PermitNotAllowedForEth();
        } else {
            if (msg.value != 0) revert InvalidMsgValue();
            if (permit.length > 0) {
                // Attempt EIP-2612 permit. Silently catches reverts so that a frontrunner
                // who submits the permit separately cannot grief the deposit transaction.
                if (permit.length == 128) {
                    (uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) =
                        abi.decode(permit, (uint256, uint8, bytes32, bytes32));
                    try IERC20Permit(tokenIn).permit(msg.sender, address(this), amountIn, permitDeadline, v, r, s) {}
                    catch {}
                }
            }
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        intents[intentId] = SwapIntent({
            intentId: intentId,
            user: msg.sender,
            status: IntentStatus.DEPOSITED,
            depositTimestamp: uint48(block.timestamp),
            solver: solver,
            deadline: uint48(deadline),
            tokenIn: tokenIn,
            amountIn: amountIn,
            tokenOut: tokenOut,
            amountOutMin: amountOutMin
        });

        emit IntentDeposited(
            intentId, msg.sender, solver, tokenIn, amountIn, tokenOut, amountOutMin, uint48(deadline)
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core: settle
    // ──────────────────────────────────────────────────────────────────────

    function settle(bytes32 intentId, uint256 amountOut) external payable nonReentrant {
        SwapIntent storage intent = intents[intentId];

        if (intent.status != IntentStatus.DEPOSITED) revert IntentNotDeposited();
        if (msg.sender != intent.solver) revert NotDesignatedSolver();
        if (block.timestamp > intent.deadline) revert DeadlineExpired();
        if (amountOut < intent.amountOutMin) revert SlippageExceeded();

        if (intent.tokenOut == ETH_ADDRESS) {
            if (msg.value != amountOut) revert InvalidMsgValue();
        } else {
            if (msg.value != 0) revert InvalidMsgValue();
        }

        intent.status = IntentStatus.SETTLED;

        // Deliver output to user: ETH is already in the contract via msg.value,
        // ERC20 is pulled from solver via transferFrom.
        if (intent.tokenOut != ETH_ADDRESS) {
            IERC20(intent.tokenOut).safeTransferFrom(msg.sender, intent.user, amountOut);
        } else {
            _sendAsset(intent.tokenOut, intent.user, amountOut);
        }

        // Release locked input to solver
        _sendAsset(intent.tokenIn, msg.sender, intent.amountIn);

        emit IntentSettled(intentId, intent.user, intent.solver, intent.tokenOut, amountOut);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core: unlock
    // ──────────────────────────────────────────────────────────────────────

    function unlock(bytes32 intentId) external nonReentrant {
        SwapIntent storage intent = intents[intentId];

        if (intent.status != IntentStatus.DEPOSITED) revert IntentNotDeposited();
        if (msg.sender != intent.solver) revert NotDesignatedSolver();

        intent.status = IntentStatus.UNLOCKED;

        _sendAsset(intent.tokenIn, intent.user, intent.amountIn);

        emit IntentUnlocked(intentId, intent.user, intent.tokenIn, intent.amountIn, UnlockReason.SOLVER_CANCELLED);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core: emergencyUnlock
    // ──────────────────────────────────────────────────────────────────────

    function emergencyUnlock(bytes32 intentId) external nonReentrant {
        SwapIntent storage intent = intents[intentId];

        if (intent.status != IntentStatus.DEPOSITED) revert IntentNotDeposited();

        bool deadlineExpired = block.timestamp > intent.deadline;
        bool globalTimeoutElapsed = block.timestamp > uint256(intent.depositTimestamp) + globalUnlockTimeout;

        if (!deadlineExpired && !globalTimeoutElapsed) revert UnlockNotReady();

        intent.status = IntentStatus.UNLOCKED;

        _sendAsset(intent.tokenIn, intent.user, intent.amountIn);

        UnlockReason reason = deadlineExpired ? UnlockReason.DEADLINE_EXPIRED : UnlockReason.GLOBAL_TIMEOUT;
        emit IntentUnlocked(intentId, intent.user, intent.tokenIn, intent.amountIn, reason);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Admin: solver registry
    // ──────────────────────────────────────────────────────────────────────

    function registerSolver(address solver) external onlyOwner {
        if (solver == address(0)) revert ZeroAddress();
        if (registeredSolvers[solver]) revert SolverAlreadyRegistered();
        registeredSolvers[solver] = true;
        emit SolverRegistered(solver);
    }

    function deregisterSolver(address solver) external onlyOwner {
        if (!registeredSolvers[solver]) revert SolverNotFound();
        registeredSolvers[solver] = false;
        emit SolverDeregistered(solver);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Admin: asset whitelist
    // ──────────────────────────────────────────────────────────────────────

    function addAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (supportedAssets[asset]) revert AssetAlreadySupported();
        supportedAssets[asset] = true;
        emit AssetAdded(asset);
    }

    function removeAsset(address asset) external onlyOwner {
        if (!supportedAssets[asset]) revert AssetNotFound();
        supportedAssets[asset] = false;
        emit AssetRemoved(asset);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Admin: global unlock timeout
    // ──────────────────────────────────────────────────────────────────────

    function setGlobalUnlockTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout < MIN_GLOBAL_UNLOCK_TIMEOUT || newTimeout > MAX_GLOBAL_UNLOCK_TIMEOUT) {
            revert TimeoutOutOfRange();
        }
        globalUnlockTimeout = newTimeout;
        emit GlobalUnlockTimeoutUpdated(newTimeout);
    }

    // ──────────────────────────────────────────────────────────────────────
    // UUPS
    // ──────────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ──────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────────

    function _sendAsset(address token, address to, uint256 amount) private {
        if (token == ETH_ADDRESS) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {
        // Only accept ETH from deposit() and settle() via msg.value.
        // Direct sends are rejected to prevent untracked ETH.
        revert EthTransferFailed();
    }
}
