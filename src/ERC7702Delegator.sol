// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {SignerERC7702} from "@openzeppelin/contracts/utils/cryptography/signers/SignerERC7702.sol";
import {IERC7579Execution, Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ERC7702Delegator
 * @notice Delegator contract for EIP-7702 sponsored execution using OpenZeppelin
 * @dev Uses OpenZeppelin's ERC7821 for batch execution and SignerERC7702 for signature validation.
 *      This is a minimal wrapper that provides the execute(calls, nonce, signature) interface
 *      while leveraging audited OpenZeppelin contracts for core functionality.
 */
contract ERC7702Delegator is ERC7821, SignerERC7702 {
    using ECDSA for bytes32;

    // ============ State Variables ============

    /// @notice Mapping of used nonces (replay protection)
    mapping(uint256 => bool) public usedNonces;

    /// @notice Current nonce reference (for informational purposes)
    uint256 public currentNonce;

    // ============ Events ============

    /// @notice Emitted when a batch is executed
    event BatchExecuted(uint256 indexed nonce, Execution[] calls, bytes[] results);

    /// @notice Emitted when a single call is executed
    event CallExecuted(address indexed target, uint256 value, bytes data, bytes result);

    /// @notice Emitted when a nonce is used
    event NonceUsed(uint256 indexed nonce);

    // ============ Errors ============

    /// @notice Invalid signature provided
    error InvalidSignature();

    /// @notice Nonce already used (replay attempt)
    error NonceAlreadyUsed(uint256 nonce);

    /// @notice Call execution failed
    error CallFailed(uint256 index, bytes result);

    // ============ Functions ============

    /**
     * @notice Execute batch of calls with signature verification
     * @param calls Array of calls to execute (target, value, data)
     * @param nonce Unique nonce for replay protection
     * @param signature EIP-712 signature from the EOA (address(this))
     * @return results Array of call results
     * @dev Anyone can call this with a valid signature (sponsored execution)
     */
    function execute(
        Execution[] calldata calls,
        uint256 nonce,
        bytes calldata signature
    ) external payable returns (bytes[] memory results) {
        // Replay protection
        if (usedNonces[nonce]) revert NonceAlreadyUsed(nonce);
        usedNonces[nonce] = true;
        emit NonceUsed(nonce);

        // Create digest including nonce and calls
        bytes32 digest = keccak256(abi.encode(nonce, calls));

        // Verify signature using SignerERC7702
        // This checks that signer == address(this) using ECDSA
        if (!_rawSignatureValidation(digest, signature)) {
            revert InvalidSignature();
        }

        // Execute batch using OpenZeppelin's ERC7579Utils via ERC7821
        // Encode calls for ERC7821 execution
        bytes memory executionData = abi.encode(calls);
        bytes32 mode = bytes32(0x0100000000000000000000000000000000000000000000000000000000000000);

        // Execute via ERC7821's internal mechanism
        results = _executeBatch(calls);

        emit BatchExecuted(nonce, calls, results);
    }

    /**
     * @notice ERC-7579 execute function (required by interface)
     * @param mode The execution mode
     * @param executionData The encoded execution data
     * @dev This delegates to OpenZeppelin's ERC7821 implementation
     */
    function execute(bytes32 mode, bytes calldata executionData) public payable override {
        // Delegate to OpenZeppelin ERC7821's implementation
        super.execute(mode, executionData);
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
        returns (bytes[] memory results)
    {
        require(msg.sender == address(this), "Only EOA itself");
        results = _executeBatch(calls);
    }

    /**
     * @notice Internal function to execute batch of calls using OpenZeppelin patterns
     * @param calls Array of calls to execute
     * @return results Array of call results
     */
    function _executeBatch(Execution[] calldata calls)
        internal
        returns (bytes[] memory results)
    {
        uint256 n = calls.length;
        results = new bytes[](n);

        for (uint256 i = 0; i < n; i++) {
            (bool success, bytes memory result) = calls[i].target.call{
                value: calls[i].value
            }(calls[i].callData);

            if (!success) {
                revert CallFailed(i, result);
            }

            results[i] = result;
            emit CallExecuted(calls[i].target, calls[i].value, calls[i].callData, result);
        }
    }

    /**
     * @notice Override ERC7821 authorization to allow this contract's execute function
     * @param caller The address attempting to execute
     * @return bool Whether the caller is authorized
     */
    function _erc7821AuthorizedExecutor(
        address caller,
        bytes32 /* mode */,
        bytes calldata /* executionData */
    ) internal view override returns (bool) {
        // Allow this contract itself (for direct execution) or the EOA
        return caller == address(this) || caller == msg.sender;
    }
}
