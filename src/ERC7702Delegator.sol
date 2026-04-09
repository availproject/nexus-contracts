// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {SignerERC7702} from "@openzeppelin/contracts/utils/cryptography/signers/SignerERC7702.sol";
import {IERC7579Execution, Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ERC7702Delegator
 * @notice Delegator contract for EIP-7702 sponsored execution using OpenZeppelin
 * @dev Uses OpenZeppelin's ERC7821 for batch execution and SignerERC7702 for signature validation.
 *      EIP-712 domain separator binds signatures to this contract and chain, preventing cross-chain replay.
 *      This is a minimal wrapper that provides the execute(calls, nonce, deadline, signature) interface
 *      while leveraging audited OpenZeppelin contracts for core functionality.
 */
contract ERC7702Delegator is ERC7821, SignerERC7702, EIP712, ReentrancyGuard {

    // ============ Type Hashes ============

    /// @notice EIP-712 typehash for Execute struct (includes deadline)
    bytes32 private constant EXECUTE_TYPEHASH =
        keccak256("Execute(uint256 nonce,uint256 deadline,Execution[] calls)Execution(address target,uint256 value,bytes callData)");

    /// @notice EIP-712 typehash for Execution struct
    bytes32 private constant EXECUTION_TYPEHASH =
        keccak256("Execution(address target,uint256 value,bytes callData)");

    // ============ State Variables ============

    /// @notice Mapping of used nonces (replay protection)
    mapping(uint256 => bool) public usedNonces;

    // ============ Events ============

    /// @notice Emitted when a batch is executed
    event BatchExecuted(uint256 indexed nonce, Execution[] calls, bytes[] results);

    /// @notice Emitted when a single call is executed
    event CallExecuted(address indexed target, uint256 value, bytes data, bytes result);

    /// @notice Emitted when a nonce is used
    event NonceUsed(uint256 indexed nonce);

    /// @notice Emitted when a nonce is cancelled
    event NonceCancelled(uint256 indexed nonce);

    // ============ Errors ============

    /// @notice Invalid signature provided
    error InvalidSignature();

    /// @notice Nonce already used (replay attempt)
    error NonceAlreadyUsed(uint256 nonce);

    /// @notice Call execution failed
    error CallFailed(uint256 index, bytes result);

    /// @notice Signature has expired
    error DeadlineExpired(uint256 deadline, uint256 currentTimestamp);

    /// @notice Empty calls array
    error EmptyCalls();

    /// @notice Insufficient msg.value for batch
    error InsufficientValue(uint256 required, uint256 provided);

    // ============ Constructor ============

    constructor() EIP712("ERC7702Delegator", "1") {}

    // ============ Functions ============

    /**
     * @notice Execute batch of calls with EIP-712 signature verification
     * @param calls Array of calls to execute (target, value, data)
     * @param nonce Unique nonce for replay protection
     * @param deadline Timestamp after which the signature is invalid (0 = no expiry)
     * @param signature EIP-712 signature from the EOA (address(this))
     * @return results Array of call results
     * @dev Anyone can call this with a valid signature (sponsored execution).
     *      Signature is bound to this contract and chain via EIP-712 domain separator.
     */
    function execute(
        Execution[] calldata calls,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external payable nonReentrant returns (bytes[] memory results) {
        // Deadline check (0 means no expiry)
        if (deadline != 0 && block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }

        // Require non-empty calls
        if (calls.length == 0) revert EmptyCalls();

        // Replay protection
        if (usedNonces[nonce]) revert NonceAlreadyUsed(nonce);
        usedNonces[nonce] = true;
        emit NonceUsed(nonce);

        // Validate msg.value covers total value
        uint256 totalValue;
        for (uint256 i = 0; i < calls.length; i++) {
            totalValue += calls[i].value;
        }
        if (msg.value < totalValue && address(this).balance < totalValue) {
            revert InsufficientValue(totalValue, msg.value);
        }

        // EIP-712 typed data hash with domain separator
        bytes32 structHash = keccak256(abi.encode(
            EXECUTE_TYPEHASH,
            nonce,
            deadline,
            _hashExecutions(calls)
        ));
        bytes32 digest = _hashTypedDataV4(structHash);

        // Verify signature using SignerERC7702
        if (!_rawSignatureValidation(digest, signature)) {
            revert InvalidSignature();
        }

        // Execute batch
        results = _executeBatch(calls);

        emit BatchExecuted(nonce, calls, results);
    }

    /**
     * @notice Cancel a nonce to invalidate a signed-but-unsubmitted transaction
     * @param nonce The nonce to cancel
     * @dev Only callable by the EOA itself (address(this))
     */
    function cancelNonce(uint256 nonce) external {
        require(msg.sender == address(this), "Only EOA itself");
        if (usedNonces[nonce]) revert NonceAlreadyUsed(nonce);
        usedNonces[nonce] = true;
        emit NonceCancelled(nonce);
    }

    /**
     * @notice Execute batch directly (no signature needed)
     * @param calls Array of calls to execute
     * @return results Array of call results
     * @dev Only callable by the EOA itself (address(this))
     */
    function execute(Execution[] calldata calls)
        external
        payable
        nonReentrant
        returns (bytes[] memory results)
    {
        require(msg.sender == address(this), "Only EOA itself");
        if (calls.length == 0) revert EmptyCalls();
        results = _executeBatch(calls);
    }

    // ============ Internal Functions ============

    /**
     * @notice Hash an array of Execution structs for EIP-712
     * @param calls Array of Execution structs
     * @return The keccak256 hash of the encoded array per EIP-712
     */
    function _hashExecutions(Execution[] calldata calls) internal pure returns (bytes32) {
        bytes32[] memory hashedCalls = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            hashedCalls[i] = keccak256(abi.encode(
                EXECUTION_TYPEHASH,
                calls[i].target,
                calls[i].value,
                keccak256(calls[i].callData)
            ));
        }
        return keccak256(abi.encodePacked(hashedCalls));
    }

    /**
     * @notice Internal function to execute batch of calls
     * @param calls Array of calls to execute
     * @return results Array of call results
     * @dev Per ERC-7821 spec: address(0) targets are replaced with address(this)
     */
    function _executeBatch(Execution[] calldata calls)
        internal
        returns (bytes[] memory results)
    {
        uint256 n = calls.length;
        results = new bytes[](n);

        for (uint256 i = 0; i < n; i++) {
            // Per ERC-7821: address(0) is replaced with address(this)
            address target = calls[i].target == address(0) ? address(this) : calls[i].target;

            (bool success, bytes memory result) = target.call{value: calls[i].value}(
                calls[i].callData
            );

            if (!success) {
                revert CallFailed(i, result);
            }

            results[i] = result;
            emit CallExecuted(target, calls[i].value, calls[i].callData, result);
        }
    }

    /**
     * @notice Override ERC7821 authorization to only allow self-execution
     * @param caller The address attempting to execute
     * @return bool Whether the caller is authorized
     * @dev Standard ERC7821 behavior: only address(this) can execute.
     *      For sponsored execution, use execute(calls, nonce, deadline, signature) instead.
     */
    function _erc7821AuthorizedExecutor(
        address caller,
        bytes32 /* mode */,
        bytes calldata /* executionData */
    ) internal view override returns (bool) {
        return caller == address(this);
    }
}
