// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {EIP712} from "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {CAIP2} from "lib/openzeppelin-contracts/contracts/utils/CAIP2.sol";
import {CAIP10} from "lib/openzeppelin-contracts/contracts/utils/CAIP10.sol";
import {Strings} from "lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {IERC7683} from "./interfaces/IERC7683.sol";
import {IDestinationSettler} from "./interfaces/IDestinationSettler.sol";
import {IOriginSettler} from "./interfaces/IOriginSettler.sol";
import {INexusSettler} from "./interfaces/INexusSettler.sol";

contract NexusSettler is EIP712, IERC7683, IDestinationSettler, IOriginSettler, INexusSettler {
    using Address for address;
    using CAIP2 for string;
    using Strings for string;

    bytes32 private constant INTENT_TYPEHASH = keccak256("Intent(Action[] actions,bytes32 sender,bytes32 recipient,string domain,uint256 nonce)");

    mapping(bytes32 => bool) ordersSent;
    mapping(bytes32 => bool) ordersFilled;

    constructor() EIP712("NexusSettler", "1") {}

    function openFor(GaslessCrossChainOrder calldata order, bytes calldata signature, bytes calldata originFillerData) external {
        // Implementation goes here
    }

    function open(OnchainCrossChainOrder calldata order) external {
        ResolvedCrossChainOrder memory resolvedOrder = _resolve(order);
        emit Open(resolvedOrder.orderId, resolvedOrder);
        ordersSent[resolvedOrder.orderId] = true;
    }

    function fill(bytes32 orderId, bytes calldata originData, bytes calldata) external {
        require(keccak256(originData) == orderId, InvalidOrderId());
        OnchainCrossChainOrder memory order = abi.decode(originData, (OnchainCrossChainOrder));
        Intent memory intent = abi.decode(order.orderData, (Intent));
        for(uint256 i = 0; i < intent.actions.length;) {
            Action memory action = intent.actions[i];
            if (action.domain.equal(CAIP2.local())) {
                emit Executed(orderId, action.actionType, action);
                for(uint256 j = 0; j < action.venue.length;) {
                    Venue memory venue = action.venue[j];
                    address target = venue.target.parseAddress();
                    target.functionCallWithValue(venue.callData, venue.value);
                    unchecked {
                        ++j;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }
        emit Filled(orderId);
    }

    function resolveFor(GaslessCrossChainOrder calldata order, bytes calldata originFillerData) external view override returns (ResolvedCrossChainOrder memory) {
        // Implementation goes here
    }

    function resolve(OnchainCrossChainOrder calldata order) external view override returns (ResolvedCrossChainOrder memory) {
        return _resolve(order);
    }

    function _resolve(OnchainCrossChainOrder calldata order) private view returns (ResolvedCrossChainOrder memory) {
        bytes32 orderId = keccak256(abi.encode(order));
        require(!ordersSent[orderId], OrderSent());
        require(order.orderDataType == INTENT_TYPEHASH, InvalidOrderDataType());
        Intent memory intent = abi.decode(order.orderData, (Intent));
        require(intent.domain.equal(CAIP2.local()), InvalidDomain());
        require(intent.sender == bytes32(uint256(uint160(msg.sender))), InvalidSender());
        Output[] memory maxSpent = new Output[](0);
        Output[] memory minReceived = new Output[](0);
        FillInstruction[] memory fillInstructions = new FillInstruction[](intent.actions.length);
        for(uint256 i = 0; i < intent.actions.length;) {
            Action memory action = intent.actions[i];
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
