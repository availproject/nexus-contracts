// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {EIP712} from "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {CAIP2} from "lib/openzeppelin-contracts/contracts/utils/CAIP2.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {SlotDerivation} from "lib/openzeppelin-contracts/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "lib/openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC7683} from "./interfaces/IERC7683.sol";
import {IDestinationSettler} from "./interfaces/IDestinationSettler.sol";
import {IOriginSettler} from "./interfaces/IOriginSettler.sol";
import {INexusSettler} from "./interfaces/INexusSettler.sol";
import {INexusVault} from "./interfaces/INexusVault.sol";

contract NexusSettler is
    ReentrancyGuardTransient,
    EIP712,
    IERC7683,
    IDestinationSettler,
    IOriginSettler,
    INexusSettler,
    Ownable
{
    using Address for address;
    using CAIP2 for string;
    using Strings for string;
    using SlotDerivation for bytes32;
    using TransientSlot for *;

    bytes32 private constant INTENT_TYPEHASH =
        keccak256(
            "Intent(Action[] actions,bytes32 sender,bytes32 recipient,string domain,uint256 nonce)"
        );
    // transient mappings
    bytes32 private constant _ALLOWANCES_NAMESPACE =
        keccak256(abi.encodePacked("nexus-settler/allowances"));
    bytes32 private constant _BALANCES_NAMESPACE =
        keccak256(abi.encodePacked("nexus-settler/balances"));

    mapping(bytes32 => bool) ordersSent;
    mapping(bytes32 => bool) ordersFilled;

    address public vault;

    constructor(
        address _initialOwner
    ) EIP712("NexusSettler", "1") Ownable(_initialOwner) {}

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    // function openFor(
    //     GaslessCrossChainOrder calldata order,
    //     bytes calldata signature,
    //     bytes calldata originFillerData
    // ) external {
    //     // Implementation goes here
    // }

    function fill(
        bytes32 orderId,
        bytes calldata originData,
        bytes calldata
    ) external nonReentrant {
        require(keccak256(originData) == orderId, InvalidOrderId());
        OnchainCrossChainOrder memory order = abi.decode(
            originData,
            (OnchainCrossChainOrder)
        );
        Intent memory intent = abi.decode(order.orderData, (Intent));
        string memory localDomain = CAIP2.local();
        Resource[] memory locks = new Resource[](intent.locks.length);
        Resource[] memory outputs = new Resource[](intent.outputs.length);
        address owner = address(bytes20(intent.sender));
        uint256 localLocks;
        uint256 localOutputs;
        uint256 i;
        // 1. check locks pertaining to this domain
        for (i = 0; i < intent.locks.length; ) {
            Resource memory resource = intent.locks[i];
            if (resource.domain.equal(localDomain)) {
                locks[localLocks] = resource;
                IERC20 token = IERC20(address(bytes20(resource.token)));
                address recipient = address(bytes20(resource.recipient));
                _setAllowance(
                    owner,
                    recipient,
                    address(token),
                    token.allowance(owner, recipient)
                );
                unchecked {
                    ++localLocks;
                }
            }
            unchecked {
                ++i;
            }
        }
        // 2. check outputs pertaining to this domain
        for (i = 0; i < intent.outputs.length; ) {
            Resource memory resource = intent.outputs[i];
            if (resource.domain.equal(localDomain)) {
                outputs[localOutputs] = resource;
                IERC20 token = IERC20(address(bytes20(resource.token)));
                _setBalance(
                    owner,
                    address(token),
                    token.balanceOf(address(bytes20(resource.recipient)))
                );
                unchecked {
                    ++localOutputs;
                }
            }
            unchecked {
                ++i;
            }
        }

        // 3. execute all batches pertaining to this domain
        for (i = 0; i < intent.batches.length; ) {
            Batch memory batch = intent.batches[i];

            if (batch.domain.equal(localDomain)) {
                for (uint256 j = 0; j < batch.actions.length; ) {
                    Action memory action = batch.actions[j];
                    emit Executed(orderId, action.actionType, batch);
                    if (action.actionType == ActionType.LOCK) {
                        Lock memory lock = abi.decode(action.data, (Lock));

                        //Lock tokens from user to the vault.
                        INexusVault(vault).lock(lock);
                    } else if (action.actionType == ActionType.FUND) {
                        Fund memory fund = abi.decode(action.data, (Fund));

                        //Transfers the tokens from solver to this contract.
                        IERC20 token = IERC20(address(bytes20(fund.token)));
                        token.transferFrom(
                            msg.sender,
                            address(this),
                            fund.amount
                        );
                    } else {
                        Venue[] memory venues = abi.decode(
                            action.data,
                            (Venue[])
                        );

                        for (uint256 k = 0; k < venues.length; ) {
                            Venue memory venue = venues[k];
                            address target = venue.target.parseAddress();
                            target.functionCallWithValue(
                                venue.callData,
                                venue.value
                            );
                            unchecked {
                                ++k;
                            }
                        }
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        // 4. validate locks pertaining to this domain
        for (i = 0; i < localLocks; ) {
            Resource memory resource = intent.locks[i];
            if (resource.domain.equal(localDomain)) {
                locks[localLocks] = resource;
                IERC20 token = IERC20(address(bytes20(resource.token)));
                address recipient = address(bytes20(resource.recipient));
                uint256 oldAllowance = _allowances(
                    owner,
                    recipient,
                    address(token)
                );
                require(
                    token.allowance(owner, recipient) >=
                        oldAllowance + resource.amount,
                    InvalidLock()
                );
            }
            unchecked {
                ++i;
            }
        }
        // 5. validate outputs pertaining to this domain
        for (i = 0; i < localOutputs; ) {
            Resource memory resource = intent.outputs[i];
            if (resource.domain.equal(localDomain)) {
                outputs[localOutputs] = resource;
                IERC20 token = IERC20(address(bytes20(resource.token)));
                address recipient = address(bytes20(resource.recipient));
                uint256 oldBalance = _balances(recipient, address(token));
                require(
                    token.balanceOf(recipient) >= oldBalance + resource.amount,
                    InvalidLock()
                );
            }
            unchecked {
                ++i;
            }
        }
        emit Filled(orderId);

        //TODO: Transfer output to user or assume it is part of action.
    }

    // function resolveFor(
    //     GaslessCrossChainOrder calldata order,
    //     bytes calldata originFillerData
    // ) external view override returns (ResolvedCrossChainOrder memory) {
    //     // Implementation goes here
    // }

    function resolve(
        OnchainCrossChainOrder calldata order
    ) external view override returns (ResolvedCrossChainOrder memory) {
        return _resolve(order);
    }

    function _resolve(
        OnchainCrossChainOrder calldata order
    ) private view returns (ResolvedCrossChainOrder memory) {
        bytes32 orderId = keccak256(abi.encode(order));
        require(!ordersSent[orderId], OrderSent());
        require(order.orderDataType == INTENT_TYPEHASH, InvalidOrderDataType());
        Intent memory intent = abi.decode(order.orderData, (Intent));
        require(intent.domain.equal(CAIP2.local()), InvalidDomain());
        require(intent.sender == bytes32(bytes20(msg.sender)), InvalidSender());
        Output[] memory maxSpent = new Output[](intent.locks.length);
        Output[] memory minReceived = new Output[](intent.outputs.length);
        FillInstruction[] memory fillInstructions = new FillInstruction[](
            intent.batches.length
        );
        uint256 i;
        for (; i < intent.locks.length; ) {
            Resource memory resource = intent.locks[i];
            (string memory namespace, string memory ref) = resource
                .domain
                .parse();
            require(namespace.equal("eip155"), InvalidDomain());
            maxSpent[i] = Output({
                token: resource.token,
                amount: resource.amount,
                recipient: resource.recipient,
                chainId: ref.parseUint()
            });
            unchecked {
                ++i;
            }
        }
        for (i = 0; i < intent.outputs.length; ) {
            Resource memory resource = intent.outputs[i];
            (string memory namespace, string memory ref) = resource
                .domain
                .parse();
            require(namespace.equal("eip155"), InvalidDomain());
            maxSpent[i] = Output({
                token: resource.token,
                amount: resource.amount,
                recipient: resource.recipient,
                chainId: ref.parseUint()
            });
            unchecked {
                ++i;
            }
        }
        for (i = 0; i < intent.batches.length; ) {
            Batch memory batch = intent.batches[i];
            (string memory namespace, string memory ref) = batch.domain.parse();
            require(namespace.equal("eip155"), InvalidDomain());
            fillInstructions[i] = FillInstruction({
                destinationChainId: ref.parseUint(),
                destinationSettler: batch.settler,
                originData: abi.encode(order)
            });
            unchecked {
                ++i;
            }
        }
        return
            ResolvedCrossChainOrder({
                user: msg.sender,
                originChainId: block.chainid,
                openDeadline: uint32(block.timestamp),
                fillDeadline: order.fillDeadline,
                orderId: orderId,
                maxSpent: maxSpent,
                minReceived: minReceived,
                fillInstructions: fillInstructions
            });
    }

    function _setAllowance(
        address owner,
        address spender,
        address token,
        uint256 amount
    ) private {
        _ALLOWANCES_NAMESPACE
            .deriveMapping(owner)
            .deriveMapping(spender)
            .deriveMapping(token)
            .asUint256()
            .tstore(amount);
    }

    function _setBalance(
        address recipient,
        address token,
        uint256 amount
    ) private {
        _BALANCES_NAMESPACE
            .deriveMapping(recipient)
            .deriveMapping(token)
            .asUint256()
            .tstore(amount);
    }

    function _allowances(
        address owner,
        address spender,
        address token
    ) private view returns (uint256) {
        return
            _ALLOWANCES_NAMESPACE
                .deriveMapping(owner)
                .deriveMapping(spender)
                .deriveMapping(token)
                .asUint256()
                .tload();
    }

    function _balances(
        address recipient,
        address token
    ) private view returns (uint256) {
        return
            _BALANCES_NAMESPACE
                .deriveMapping(recipient)
                .deriveMapping(token)
                .asUint256()
                .tload();
    }
}

/* 
struct ResolvedCrossChainOrder {
    /// @dev The address of the user who is initiating the transfer
    address user;
    /// @dev The chainId of the origin chain
    uint256 originChainId;
    /// @dev The timestamp by which the order must be opened
    uint32 openDeadline;
    /// @dev The timestamp by which the order must be filled on the destination chain(s)
    uint32 fillDeadline;
    /// @dev The unique identifier for this order within this settlement system
    bytes32 orderId;

    /// @dev The max outputs that the filler will send. It's possible the actual amount depends on the state of the destination
    ///      chain (destination dutch auction, for instance), so these outputs should be considered a cap on filler liabilities.
    Output[] maxSpent;
    /// @dev The minimum outputs that must to be given to the filler as part of order settlement. Similar to maxSpent, it's possible
    ///      that special order types may not be able to guarantee the exact amount at open time, so this should be considered
    ///      a floor on filler receipts.
    Output[] minReceived;
    /// @dev Each instruction in this array is parameterizes a single leg of the fill. This provides the filler with the information
    ///      necessary to perform the fill on the destination(s).
    FillInstruction[] fillInstructions;
}
*/
