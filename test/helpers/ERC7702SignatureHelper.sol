// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC7821} from "lib/openzeppelin-contracts/contracts/interfaces/draft-IERC7821.sol";
import {EIP7702Utils} from "lib/openzeppelin-contracts/contracts/account/utils/EIP7702Utils.sol";
import {ERC7579Utils, Execution} from "lib/openzeppelin-contracts/contracts/account/utils/draft-ERC7579Utils.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

import {Vm} from "lib/forge-std/src/Vm.sol";

/**
 * @title ERC7702SignatureHelper
 * @notice Utility library for generating EIP-7702 delegated execution signatures
 * @dev Used for testing ERC7702Delegator and intent-based execution.
 *      Computes EIP-712 typed data hashes matching the contract's verification.
 */
library ERC7702SignatureHelper {
    using ERC7579Utils for *;

    Vm private constant vm1 = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice EIP-712 typehash for Execute struct (must match ERC7702Delegator)
    bytes32 internal constant EXECUTE_TYPEHASH =
        keccak256("Execute(uint256 nonce,uint256 deadline,Execution[] calls)Execution(address target,uint256 value,bytes callData)");

    /// @notice EIP-712 typehash for Execution struct
    bytes32 internal constant EXECUTION_TYPEHASH =
        keccak256("Execution(address target,uint256 value,bytes callData)");

    /**
     * @dev Generates an ECDSA signature for the given digest
     * @param digest The hash to sign
     * @param privateKey The private key to sign with
     * @return signature The 65-byte ECDSA signature (r, s, v)
     */
    function generateSignature(bytes32 digest, uint256 privateKey) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm1.sign(privateKey, digest);
        signature = bytes.concat(r, s, bytes1(v));
    }

    /**
     * @dev Recovers the signer address from a signature
     * @param digest The hash that was signed
     * @param signature The signature to recover from
     * @return signer The recovered address
     */
    function recoverSigner(bytes32 digest, bytes memory signature) internal pure returns (address signer) {
        require(signature.length == 65, "invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        signer = ecrecover(digest, v, r, s);
    }

    /**
     * @dev Hash an array of Execution structs per EIP-712
     * @param calls Array of Execution structs
     * @return The keccak256 hash of the encoded array
     */
    function hashExecutions(Execution[] memory calls) internal pure returns (bytes32) {
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
     * @dev Computes the EIP-712 typed data hash for execute(calls, nonce, deadline, signature)
     * @param delegator The ERC7702Delegator contract address (verifying contract for EIP-712 domain)
     * @param nonce The nonce value
     * @param deadline The deadline timestamp (0 = no expiry)
     * @param calls The array of Execution structs
     * @return digest The EIP-712 typed data hash ready for signing
     */
    function computeExecuteDigest(
        address delegator,
        uint256 nonce,
        uint256 deadline,
        Execution[] memory calls
    ) internal view returns (bytes32) {
        // Compute struct hash per EIP-712
        bytes32 structHash = keccak256(abi.encode(
            EXECUTE_TYPEHASH,
            nonce,
            deadline,
            hashExecutions(calls)
        ));

        // Compute domain separator (must match contract's EIP712("ERC7702Delegator", "1"))
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("ERC7702Delegator")),
            keccak256(bytes("1")),
            block.chainid,
            delegator
        ));

        // EIP-712 typed data hash
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /**
     * @dev Encodes calls for EIP-7702 execution digest
     * @param calls The array of executions to encode
     * @return encoded The encoded calls (ERC7821 batch format)
     */
    function encodeCalls(Execution[] memory calls) internal pure returns (bytes memory encoded) {
        return calls.encodeBatch();
    }

    /**
     * @dev Creates execution data for ERC7821 execute call
     * @param calls The array of executions
     * @return executionData The encoded execution data
     */
    function createExecuteData(Execution[] memory calls) internal pure returns (bytes memory executionData) {
        return abi.encode(calls);
    }

    /**
     * @dev Creates a single call execution
     * @param target The target address
     * @param value The value to send
     * @param data The call data
     * @return execution The execution struct
     */
    function createCall(address target, uint256 value, bytes memory data) internal pure returns (Execution memory execution) {
        execution = Execution({target: target, value: value, callData: data});
    }

    /**
     * @dev Creates an EIP-7702 authorization nonce digest
     * @param delegator The delegator address (EOA or smart contract)
     * @param nonce The nonce value
     * @return digest The authorization digest
     */
    function createAuthorizationDigest(address delegator, uint256 nonce) internal view returns (bytes32 digest) {
        return keccak256(abi.encode(delegator, nonce, block.chainid));
    }

    /**
     * @dev Creates an EIP-7702 delegation authorization
     * @param delegator The delegator address
     * @param delegate The delegate contract address
     * @param nonce The nonce
     * @param privateKey The private key to sign with
     * @return authorization The authorization bytes
     */
    function createAuthorization(
        address delegator,
        address delegate,
        uint256 nonce,
        uint256 privateKey
    ) internal view returns (bytes memory authorization) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                bytes1(0x05),
                delegator,
                delegate,
                nonce,
                block.chainid,
                block.prevrandao
            )
        );
        bytes memory sig = generateSignature(digest, privateKey);
        return abi.encodePacked(delegate, nonce, sig);
    }
}