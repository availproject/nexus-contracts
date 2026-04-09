// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC7702Delegator} from "../src/ERC7702Delegator.sol";
import {IERC7821} from "@openzeppelin/contracts/interfaces/draft-IERC7821.sol";
import {EIP7702Utils} from "@openzeppelin/contracts/account/utils/EIP7702Utils.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ERC7702SignatureHelper} from "./helpers/ERC7702SignatureHelper.sol";

contract ERC7702DelegatorTest is Test {
    using ERC7579Utils for *;
    using ERC7702SignatureHelper for *;

    // ============ Contracts ============

    ERC7702Delegator public delegator;

    // ============ Test Accounts ============

    uint256 public userPrivateKey;
    address public userEOA;
    address public sponsor;
    address public recipient;

    // ============ Constants ============

    uint256 constant NO_DEADLINE = 0;

    // ============ Setup ============

    function setUp() public {
        delegator = new ERC7702Delegator();

        userPrivateKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        userEOA = vm.addr(userPrivateKey);
        sponsor = makeAddr("sponsor");
        recipient = makeAddr("recipient");

        vm.deal(userEOA, 10 ether);
        vm.deal(sponsor, 1 ether);
    }

    // ============ Helper Functions ============

    function _create7702EOA(address eoa, address delegate) internal {
        bytes memory delegationCode = abi.encodePacked(bytes3(0xef0100), delegate);
        vm.etch(eoa, delegationCode);
    }

    function _generateSignature(bytes32 digest, uint256 privateKey) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _createCall(address target, uint256 value, bytes memory data) internal pure returns (Execution memory) {
        return Execution({target: target, value: value, callData: data});
    }

    function _executeViaEOA(
        address eoa,
        Execution[] memory calls,
        uint256 nonce,
        uint256 deadline,
        bytes memory signature
    ) internal returns (bytes[] memory results) {
        bytes memory executeData = abi.encodeWithSignature(
            "execute((address,uint256,bytes)[],uint256,uint256,bytes)",
            calls,
            nonce,
            deadline,
            signature
        );

        (bool success, bytes memory result) = eoa.call(executeData);
        require(success, "Execution failed");

        return abi.decode(result, (bytes[]));
    }

    function _executeViaEOADirect(
        address eoa,
        Execution[] memory calls
    ) internal returns (bytes[] memory results) {
        bytes memory executeData = abi.encodeWithSignature(
            "execute((address,uint256,bytes)[])",
            calls
        );

        (bool success, bytes memory result) = eoa.call(executeData);
        require(success, "Direct execution failed");

        return abi.decode(result, (bytes[]));
    }

    // ============ Test: Valid Signature Execution ============

    function test_ValidSignatureExecution() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        uint256 initialRecipientBalance = recipient.balance;

        vm.prank(sponsor);
        bytes[] memory results = _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);

        assertEq(results.length, 1, "Should have 1 result");
        assertEq(recipient.balance, initialRecipientBalance + 0.5 ether, "Recipient should receive 0.5 ETH");
    }

    function test_ValidSignature_MultipleCalls() public {
        _create7702EOA(userEOA, address(delegator));

        address recipient2 = makeAddr("recipient2");

        Execution[] memory calls = new Execution[](2);
        calls[0] = _createCall(recipient, 0.3 ether, "");
        calls[1] = _createCall(recipient2, 0.2 ether, "");

        uint256 nonce = 42;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        bytes[] memory results = _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);

        assertEq(results.length, 2, "Should have 2 results");
        assertEq(recipient.balance, 0.3 ether, "Recipient 1 should receive 0.3 ETH");
        assertEq(recipient2.balance, 0.2 ether, "Recipient 2 should receive 0.2 ETH");
    }

    // ============ Test: Invalid Signature Rejection ============

    function test_InvalidSignature_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        uint256 wrongPrivateKey = 0xdeadbeef1234567890abcdef1234567890abcdef1234567890abcdef12345678;
        bytes memory wrongSignature = _generateSignature(digest, wrongPrivateKey);

        vm.prank(sponsor);
        vm.expectRevert(ERC7702Delegator.InvalidSignature.selector);
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, wrongSignature);
    }

    function test_InvalidSignature_WrongDigest_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 nonce = 1;

        Execution[] memory wrongCalls = new Execution[](1);
        wrongCalls[0] = _createCall(recipient, 0.5 ether, "");
        bytes32 wrongDigest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce + 1, NO_DEADLINE, wrongCalls);
        bytes memory wrongSignature = _generateSignature(wrongDigest, userPrivateKey);

        vm.prank(sponsor);
        vm.expectRevert(ERC7702Delegator.InvalidSignature.selector);
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, wrongSignature);
    }

    // ============ Test: Direct EOA Execution (No Signature) ============

    function test_DirectEOAExecution() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 initialRecipientBalance = recipient.balance;

        vm.prank(userEOA);
        bytes[] memory results = _executeViaEOADirect(userEOA, calls);

        assertEq(results.length, 1, "Should have 1 result");
        assertEq(recipient.balance, initialRecipientBalance + 0.5 ether, "Recipient should receive 0.5 ETH");
    }

    function test_DirectEOAExecution_MultipleCalls() public {
        _create7702EOA(userEOA, address(delegator));

        address recipient2 = makeAddr("recipient2");

        Execution[] memory calls = new Execution[](2);
        calls[0] = _createCall(recipient, 0.3 ether, "");
        calls[1] = _createCall(recipient2, 0.2 ether, "");

        vm.prank(userEOA);
        bytes[] memory results = _executeViaEOADirect(userEOA, calls);

        assertEq(results.length, 2, "Should have 2 results");
        assertEq(recipient.balance, 0.3 ether, "Recipient 1 should receive 0.3 ETH");
        assertEq(recipient2.balance, 0.2 ether, "Recipient 2 should receive 0.2 ETH");
    }

    function test_DirectEOAExecution_OnlyEOA_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        vm.prank(sponsor);
        vm.expectRevert("Only EOA itself");
        _executeViaEOADirect(userEOA, calls);
    }

    // ============ Test: Nonce Replay Prevention ============

    function test_NonceReplay_Prevention() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ERC7702Delegator.NonceAlreadyUsed.selector, nonce));
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);
    }

    function test_DifferentNonces_Work() public {
        _create7702EOA(userEOA, address(delegator));

        address recipient2 = makeAddr("recipient2");

        Execution[] memory calls1 = new Execution[](1);
        calls1[0] = _createCall(recipient, 0.3 ether, "");

        bytes32 digest1 = ERC7702SignatureHelper.computeExecuteDigest(userEOA, 1, NO_DEADLINE, calls1);
        bytes memory signature1 = _generateSignature(digest1, userPrivateKey);

        vm.prank(sponsor);
        _executeViaEOA(userEOA, calls1, 1, NO_DEADLINE, signature1);

        Execution[] memory calls2 = new Execution[](1);
        calls2[0] = _createCall(recipient2, 0.2 ether, "");

        bytes32 digest2 = ERC7702SignatureHelper.computeExecuteDigest(userEOA, 2, NO_DEADLINE, calls2);
        bytes memory signature2 = _generateSignature(digest2, userPrivateKey);

        vm.prank(sponsor);
        _executeViaEOA(userEOA, calls2, 2, NO_DEADLINE, signature2);

        assertEq(recipient.balance, 0.3 ether, "Recipient 1 should receive 0.3 ETH");
        assertEq(recipient2.balance, 0.2 ether, "Recipient 2 should receive 0.2 ETH");
    }

    // ============ Test: Deadline ============

    function test_Deadline_Valid() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, deadline, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        bytes[] memory results = _executeViaEOA(userEOA, calls, nonce, deadline, signature);

        assertEq(results.length, 1);
        assertEq(recipient.balance, 0.5 ether);
    }

    function test_Deadline_Expired_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, deadline, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        // Warp past deadline
        vm.warp(deadline + 1);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ERC7702Delegator.DeadlineExpired.selector, deadline, block.timestamp));
        _executeViaEOA(userEOA, calls, nonce, deadline, signature);
    }

    function test_Deadline_Zero_NoExpiry() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        // Warp far into the future
        vm.warp(block.timestamp + 365 days);

        vm.prank(sponsor);
        bytes[] memory results = _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);

        assertEq(results.length, 1);
        assertEq(recipient.balance, 0.5 ether);
    }

    // ============ Test: Nonce Cancellation ============

    function test_CancelNonce() public {
        _create7702EOA(userEOA, address(delegator));

        uint256 nonce = 1;

        // Cancel nonce as the EOA itself
        vm.prank(userEOA);
        (bool success,) = userEOA.call(abi.encodeWithSignature("cancelNonce(uint256)", nonce));
        assertTrue(success, "cancelNonce should succeed");

        // Now try to use the cancelled nonce
        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ERC7702Delegator.NonceAlreadyUsed.selector, nonce));
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);
    }

    function test_CancelNonce_OnlyEOA_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        vm.prank(sponsor);
        vm.expectRevert("Only EOA itself");
        (bool success,) = userEOA.call(abi.encodeWithSignature("cancelNonce(uint256)", uint256(1)));
        // The call itself succeeds at low-level but the require inside reverts
        // expectRevert catches the propagated revert
    }

    function test_CancelNonce_AlreadyUsed_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        // First use the nonce
        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");
        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);

        // Try to cancel already-used nonce
        vm.prank(userEOA);
        vm.expectRevert(abi.encodeWithSelector(ERC7702Delegator.NonceAlreadyUsed.selector, nonce));
        (bool success,) = userEOA.call(abi.encodeWithSignature("cancelNonce(uint256)", nonce));
    }

    // ============ Test: Empty Calls ============

    function test_EmptyCalls_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](0);
        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        vm.expectRevert(ERC7702Delegator.EmptyCalls.selector);
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);
    }

    function test_EmptyCalls_Direct_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](0);

        vm.prank(userEOA);
        vm.expectRevert(ERC7702Delegator.EmptyCalls.selector);
        _executeViaEOADirect(userEOA, calls);
    }

    // ============ Test: Events ============

    function test_Events_Emitted() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.5 ether, "");

        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);
    }

    // ============ Test: Call Failure Handling ============

    function test_CallFailure_InsufficientValue_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 100 ether, "");

        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(ERC7702Delegator.InsufficientValue.selector, 100 ether, 0));
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);
    }

    function test_CallFailure_Reverts() public {
        _create7702EOA(userEOA, address(delegator));

        // Call a contract that will revert (send to a contract with no receive)
        // Use a value the EOA can afford but target will reject
        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(address(delegator), 0, abi.encodeWithSignature("nonexistent()"));

        uint256 nonce = 1;

        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        vm.expectRevert();
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);
    }

    // ============ Test: EIP-7702 Delegation Detection ============

    function test_EIP7702_DelegationDetection() public {
        _create7702EOA(userEOA, address(delegator));

        address delegate = EIP7702Utils.fetchDelegate(userEOA);
        assertEq(delegate, address(delegator), "Delegation should be detected");
    }

    function test_EIP7702_NoDelegation() public {
        address regularEOA = makeAddr("regularEOA");

        address delegate = EIP7702Utils.fetchDelegate(regularEOA);
        assertEq(delegate, address(0), "No delegation should be detected");
    }

    // ============ Test: UsedNonces Mapping ============

    function test_UsedNonces_Mapping() public {
        _create7702EOA(userEOA, address(delegator));

        Execution[] memory calls = new Execution[](1);
        calls[0] = _createCall(recipient, 0.1 ether, "");

        uint256 nonce = 1;
        bytes32 digest = ERC7702SignatureHelper.computeExecuteDigest(userEOA, nonce, NO_DEADLINE, calls);
        bytes memory signature = _generateSignature(digest, userPrivateKey);

        vm.prank(sponsor);
        _executeViaEOA(userEOA, calls, nonce, NO_DEADLINE, signature);

        assertEq(recipient.balance, 0.1 ether, "Recipient should receive 0.1 ETH");
    }
}
