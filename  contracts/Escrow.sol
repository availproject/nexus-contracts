// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "solady/src/utils/LibString.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract Escrow is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    enum Function {
        Deposit,
        Settle
    }

    enum RFFState {
        UNPROCESSED,
        DEPOSITED_WITHOUT_GAS_REFUND,
        DEPOSITED_WITH_GAS_REFUND,
        FULFILLED
    }

    mapping(Function => uint256) public overhead;
    uint256 public vaultBalance;
    uint256 public maxGasPrice;

    mapping(bytes32 => RFFState) public requestState;
    mapping(bytes32 => address) public winningSolver;
    mapping(uint256 => bool) public depositNonce;
    mapping(uint256 => bool) public fillNonce;
    mapping(uint256 => bool) public settleNonce;
    bytes32 private constant REFUND_ACCESS = keccak256("REFUND_ACCESS");
    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Storage gap to reserve slots for future use
    uint256[50] private __gap;

    struct FundsSource {
        string domain;
        bytes32 tokenAddress;
        uint256 amount;
        bool sponsored;
        uint256 fee_amount;
    }

    enum ActionType {
        FUND
    }

    struct Fund {
        bytes32 tokenAddress;
        uint256 amount;
    }

    struct Action {
        ActionType actionType;
        string domain;
        bytes data;
    }

    struct Intent {
        Action[] actions;
        uint256 nonce;
        string domain;
        uint256 expiry;
        FundsSource[] fundsSources;
        bytes32 from;
        bytes32 outputDestination;
    }

    event Deposit(bytes32 indexed requestHash, address from, bool gasRefunded);
    event Fill(bytes32 indexed requestHash, address from, address solver);
    event Withdraw(address indexed to, address token, uint256 amount);
    event Settle(
        uint256 indexed nonce,
        address[] solver,
        address[] token,
        uint256[] amount
    );
    event GasPriceUpdate(uint256 gasPrice);
    event GasOverheadUpdate(Function indexed _function, uint256 overhead);
    event ReceiveETH(address indexed from, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REFUND_ACCESS, admin);
        _grantRole(UPGRADER_ROLE, admin);

        maxGasPrice = 50 gwei;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    function _hashIntent(
        Intent calldata intent
    ) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    intent.actions,
                    intent.nonce,
                    intent.domain,
                    intent.expiry,
                    intent.fundsSources,
                    intent.from,
                    intent.outputDestination
                )
            );
    }

    function bytes32ToAddress(bytes32 a) internal pure returns (address) {
        // Cast the last 20 bytes of bytes32 into an address
        return address(uint160(uint256(a)));
    }

    function _getCaip2ChainId() private view returns (string memory) {
        return LibString.concat("eip155:", LibString.toString(block.chainid));
    }

    function _verify_request(
        bytes calldata signature,
        address from,
        bytes32 structHash
    ) private pure returns (bool, bytes32) {
        // Prepend the Ethereum signed message prefix
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)
        );

        // Recover the signer from the signature
        address signer = ethSignedMessageHash.recover(signature);
        return (signer == from, ethSignedMessageHash);
    }

    function _deposit(
        Intent calldata intent,
        bytes calldata signature,
        uint256 chainIndex
    ) private {
        bytes32 structHash = _hashIntent(intent);
        address from = extractAddress(intent.domain, intent.from);
        (bool success, bytes32 ethSignedMessageHash) = _verify_request(
            signature,
            from,
            structHash
        );
        require(success, "Vault: Invalid signature or from");
        require(
            intent.fundsSources[chainIndex].domain == _getCaip2ChainId(),
            "Vault: Chain ID mismatch"
        );
        require(!depositNonce[intent.nonce], "Vault: Nonce already used");
        require(intent.expiry > block.timestamp, "Vault: Request expired");

        depositNonce[intent.nonce] = true;

        if (intent.fundsSources[chainIndex].tokenAddress == bytes32(0)) {
            uint256 totalValue = intent.fundsSources[chainIndex].amount;
            require(msg.value == totalValue, "Vault: Value mismatch");
        } else {
            IERC20 token = IERC20(
                bytes32ToAddress(intent.fundsSources[chainIndex].tokenAddress)
            );
            token.safeTransferFrom(
                from,
                address(this),
                intent.fundsSources[chainIndex].amount
            );
        }

        if (intent.fundsSources[chainIndex].sponsored) {
            requestState[ethSignedMessageHash] = RFFState
                .DEPOSITED_WITH_GAS_REFUND;
        } else {
            requestState[ethSignedMessageHash] = RFFState
                .DEPOSITED_WITHOUT_GAS_REFUND;
        }

        emit Deposit(
            ethSignedMessageHash,
            from,
            intent.fundsSources[chainIndex].sponsored
        );
    }

    function deposit(
        Intent calldata intent,
        bytes calldata signature,
        uint256 chainIndex
    ) external payable nonReentrant {
        _deposit(intent, signature, chainIndex);
    }

    function extractAddress(
        string calldata domain,
        bytes32 address_
    ) internal view returns (address) {
        require(
            keccak256(abi.encodePacked(domain)) ==
                keccak256(abi.encodePacked(_getCaip2ChainId())),
            "Vault: Universe not supported"
        );
        return bytes32ToAddress(address_);
    }

    function fill(
        Intent calldata intent,
        bytes calldata signature
    ) external payable nonReentrant {
        address from = extractAddress(intent.domain, intent.from);
        bytes32 structHash = _hashIntent(intent);
        (bool success, bytes32 ethSignedMessageHash) = _verify_request(
            signature,
            from,
            structHash
        );
        require(success, "Vault: Invalid signature or from");
        require(
            intent.domain == _getCaip2ChainId(),
            "Vault: Chain ID mismatch"
        );
        require(!fillNonce[intent.nonce], "Vault: Nonce already used");
        require(intent.expiry > block.timestamp, "Vault: Request expired");

        fillNonce[intent.nonce] = true;
        requestState[ethSignedMessageHash] = RFFState.FULFILLED;
        winningSolver[ethSignedMessageHash] = msg.sender;

        uint256 gasBalance = msg.value;
        emit Fill(ethSignedMessageHash, from, msg.sender);
        for (uint i = 0; i < intent.actions.length; ++i) {
            if (intent.actions[i].actionType == ActionType.FUND) {
                Fund memory actionData = abi.decode(
                    intent.actions[i].data,
                    (Fund)
                );
                if (actionData.tokenAddress == bytes32(0)) {
                    require(
                        gasBalance >= actionData.amount,
                        "Vault: Value mismatch"
                    );
                    require(actionData.amount > 0, "Vault: Value mismatch");
                    gasBalance -= actionData.amount;
                    (bool sent, ) = payable(from).call{
                        value: actionData.amount
                    }("");
                    require(sent, "Vault: Transfer failed");
                } else {
                    IERC20 token = IERC20(
                        bytes32ToAddress(actionData.tokenAddress)
                    );
                    token.safeTransferFrom(msg.sender, from, actionData.amount);
                }
            }
        }
    }

    function setMaxGasPrice(
        uint256 _maxGasPrice
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxGasPrice = _maxGasPrice;
        emit GasPriceUpdate(_maxGasPrice);
    }

    function withdraw(
        address to,
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token == address(0)) {
            (bool sent, ) = payable(to).call{value: amount}("");
            require(sent, "Vault: Transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdraw(to, token, amount);
    }

    function verifyIntentSignature(
        Intent calldata intent,
        bytes calldata signature
    ) external pure returns (bool, bytes32) {
        address from = extractAddress(intent.domain, intent.from);
        return _verify_request(signature, from, _hashIntent(intent));
    }

    function setOverHead(
        Function _function,
        uint256 _overhead
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        overhead[_function] = _overhead;
        emit GasOverheadUpdate(_function, _overhead);
    }
}
