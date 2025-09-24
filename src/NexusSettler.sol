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
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IXERC7683} from "lib/XERC7683/src/IXERC7683.sol";
import {IXOriginSettler} from "lib/XERC7683/src/IXOriginSettler.sol";
import {IXDestinationSettler} from "lib/XERC7683/src/IXDestinationSettler.sol";
import {IERC7683} from "./interfaces/IERC7683.sol";
import {IOriginSettler} from "./interfaces/IOriginSettler.sol";
import {IDestinationSettler} from "./interfaces/IDestinationSettler.sol";
import {INexusSettler} from "./interfaces/INexusSettler.sol";

contract NexusSettler is
    ReentrancyGuardTransient,
    EIP712,
    IERC7683,
    IXERC7683,
    IOriginSettler,
    IXOriginSettler,
    IDestinationSettler,
    IXDestinationSettler,
    INexusSettler
{
    using Address for address;
    using CAIP2 for string;
    using Strings for string;
    using SlotDerivation for bytes32;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    bytes32 private constant INTENT_TYPEHASH =
        keccak256("Intent(string domain,Actions[] batch,bytes32 sender,bytes32 recipient,uint256 nonce)");
    // transient mappings
    bytes32 private constant _ALLOWANCES_NAMESPACE = keccak256(abi.encodePacked("nexus-settler/allowances"));
    bytes32 private constant _BALANCES_NAMESPACE = keccak256(abi.encodePacked("nexus-settler/balances"));

    address public immutable escrow;

    mapping(bytes32 => bool) ordersSent;
    mapping(bytes32 => bool) ordersFilled;

    constructor(address newEscrow) EIP712("NexusSettler", "1") {
        escrow = newEscrow;
    }

    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData)
        external
    {
        // Implementation goes here
    }

    function openFor(XGaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData)
        external 
    {
        // Implementation goes here
    }

    function open(OnchainCrossChainOrder calldata order) override external {
        ResolvedCrossChainOrder memory resolvedOrder = _resolve(order);
        emit Open(resolvedOrder.orderId, resolvedOrder);
        ordersSent[resolvedOrder.orderId] = true;
    }

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata) override(IDestinationSettler, IXDestinationSettler) external nonReentrant {
        require(keccak256(originData) == orderId, InvalidOrderId());
        require(!ordersFilled[orderId], OrderFilled());
        OnchainCrossChainOrder memory order = abi.decode(originData, (OnchainCrossChainOrder));
        Intent memory intent = abi.decode(order.orderData, (Intent));
        string memory localDomain = CAIP2.local();
        Resource[] memory outputs = new Resource[](intent.outputs.length);
        address owner = address(bytes20(intent.sender));
        uint256 localOutputs;
        uint256 i;
        Actions memory batch;
        // extract batch for this domain
        bool flag = false;
        for (; i < intent.batch.length;) {
            Actions memory actions = intent.batch[i];
            if (actions.domain.equal(localDomain)) {
                batch = intent.batch[i];
                flag = true;
                break;
            }
            unchecked {
                ++i;
            }
        }
        // no valid batch found
        require(flag, InvalidDomain());
        // 1. check outputs pertaining to this domain
        for (i = 0; i < intent.outputs.length;) {
            Resource memory resource = intent.outputs[i];
            if (resource.domain.equal(localDomain)) {
                outputs[localOutputs] = resource;
                IERC20 token = IERC20(address(bytes20(resource.token)));
                _setBalance(owner, address(token), token.balanceOf(address(bytes20(resource.recipient))));
                unchecked {
                    ++localOutputs;
                }
            }
            unchecked {
                ++i;
            }
        }
        // update filled status, before external calls
        ordersFilled[orderId] = true;
        // 2. execute batch conditions, locks, funds, actions in order
        for (i = 0; i < batch.conditions.length;) {
            Action memory action = batch.conditions[i];
            address target = action.target.parseAddress();
            target.functionCallWithValue(action.callData, action.value);
            unchecked {
                ++i;
            }
        }
        for (i = 0; i < batch.locks.length;) {
            Lock memory lock = batch.locks[i];
            IERC20 token = IERC20(address(bytes20(lock.token)));
            token.safeTransferFrom(owner, escrow, lock.amount);
            unchecked {
                ++i;
            }
        }
        for (i = 0; i < batch.funds.length;) {
            Fund memory fund = batch.funds[i];
            IERC20 token = IERC20(address(bytes20(fund.token)));
            address recipient = address(bytes20(fund.recipient));
            token.safeTransferFrom(msg.sender, recipient, fund.amount);
            unchecked {
                ++i;
            }
        }
        for (i = 0; i < batch.actions.length;) {
            Action memory action = batch.actions[i];
            address target = action.target.parseAddress();
            target.functionCallWithValue(action.callData, action.value);
            unchecked {
                ++i;
            }
        }
        // 3. validate outputs pertaining to this domain
        for (i = 0; i < localOutputs;) {
            Resource memory resource = intent.outputs[i];
            if (resource.domain.equal(localDomain)) {
                outputs[localOutputs] = resource;
                IERC20 token = IERC20(address(bytes20(resource.token)));
                address recipient = address(bytes20(resource.recipient));
                uint256 oldBalance = _balances(recipient, address(token));
                require(token.balanceOf(recipient) >= oldBalance + resource.amount, InvalidOutput());
            }
            unchecked {
                ++i;
            }
        }
        emit Filled(orderId);
    }

    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        override
        returns (ResolvedCrossChainOrder memory)
    {
        // Implementation goes here
    }

    function resolveFor(XGaslessCrossChainOrder calldata order, bytes calldata originFillerData)
        external
        view
        override
        returns (XResolvedCrossChainOrder memory)
    {
        // Implementation goes here
    }

    function resolve(OnchainCrossChainOrder calldata order)
        external
        view
        override
        returns (ResolvedCrossChainOrder memory)
    {
        return _resolve(order);
    }

    function xresolve(XOnchainCrossChainOrder calldata order)
        external
        view
        returns (XResolvedCrossChainOrder memory)
    {
        // Implementation goes here
    }

    function _resolve(OnchainCrossChainOrder calldata order) private view returns (ResolvedCrossChainOrder memory) {
        bytes32 orderId = keccak256(abi.encode(order));
        require(!ordersSent[orderId], OrderSent());
        require(order.orderDataType == INTENT_TYPEHASH, InvalidOrderDataType());
        Intent memory intent = abi.decode(order.orderData, (Intent));
        require(intent.domain.equal(CAIP2.local()), InvalidDomain());
        require(intent.sender == bytes32(bytes20(msg.sender)), InvalidSender());
        Output[] memory maxSpent = new Output[](intent.inputs.length);
        Output[] memory minReceived = new Output[](intent.outputs.length);
        FillInstruction[] memory fillInstructions = new FillInstruction[](intent.batch.length);
        uint256 i;
        for (; i < intent.inputs.length;) {
            Resource memory resource = intent.inputs[i];
            (string memory namespace, string memory ref) = resource.domain.parse();
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
        for (i = 0; i < intent.outputs.length;) {
            Resource memory resource = intent.outputs[i];
            (string memory namespace, string memory ref) = resource.domain.parse();
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
        for (i = 0; i < intent.batch.length;) {
            Actions memory action = intent.batch[i];
            (string memory namespace, string memory ref) = action.domain.parse();
            require(namespace.equal("eip155"), InvalidDomain());
            fillInstructions[i] = FillInstruction({
                destinationChainId: ref.parseUint(),
                destinationSettler: action.settler,
                originData: abi.encode(order)
            });
            unchecked {
                ++i;
            }
        }
        return ResolvedCrossChainOrder({
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

    function _setAllowance(address owner, address spender, address token, uint256 amount) private {
        _ALLOWANCES_NAMESPACE.deriveMapping(owner).deriveMapping(spender).deriveMapping(token).asUint256().tstore(
            amount
        );
    }

    function _setBalance(address recipient, address token, uint256 amount) private {
        _BALANCES_NAMESPACE.deriveMapping(recipient).deriveMapping(token).asUint256().tstore(amount);
    }

    function _allowances(address owner, address spender, address token) private view returns (uint256) {
        return
            _ALLOWANCES_NAMESPACE.deriveMapping(owner).deriveMapping(spender).deriveMapping(token).asUint256().tload();
    }

    function _balances(address recipient, address token) private view returns (uint256) {
        return _BALANCES_NAMESPACE.deriveMapping(recipient).deriveMapping(token).asUint256().tload();
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
