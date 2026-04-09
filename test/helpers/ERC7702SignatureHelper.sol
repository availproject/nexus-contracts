// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC7821} from "lib/openzeppelin-contracts/contracts/interfaces/draft-IERC7821.sol";
import {EIP7702Utils} from "lib/openzeppelin-contracts/contracts/account/utils/EIP7702Utils.sol";
import {ERC7579Utils, Execution} from "lib/openzeppelin-contracts/contracts/account/utils/draft-ERC7579Utils.sol";
import {ECDSA} from "lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {Vm} from "lib/forge-std/src/Vm.sol";

/**
 * @title ERC7702SignatureHelper
 * @notice Utility library for generating EIP-7702 delegated execution signatures
 * @dev Used for testing ERC7702Delegator and intent-based execution
 */
library ERC7702SignatureHelper {
    using ERC7579Utils for *;

    Vm private constant vm1 = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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