// SPDX-License-Identifier: Apache-2.0
// Source: https://github.com/QEDK/XERC7683/blob/master/src/IXERC7683.sol
pragma solidity 0.8.30;

/// @title IXERC7683
/// @notice An extension of the ERC-7683 standard that supports first-class cross-VM cross-chain intents
interface IXERC7683 {
    /// @title XGaslessCrossChainOrder CrossChainOrder type
    /// @notice Standard order struct to be signed by users, disseminated to fillers, and submitted to origin settler contracts by fillers
    struct XGaslessCrossChainOrder {
        /// @dev The contract address that the order is meant to be settled by.
        /// Fillers send this order to this contract address on the origin chain
        bytes32 originSettler;
        /// @dev The address of the user who is initiating the swap,
        /// whose input tokens will be taken and escrowed
        bytes32 user;
        /// @dev Nonce to be used as replay protection for the order
        uint256 nonce;
        /// @dev The domain of the origin chain
        string domain;
        /// @dev The timestamp by which the order must be opened
        uint32 openDeadline;
        /// @dev The timestamp by which the order must be filled on the destination chain
        uint32 fillDeadline;
        /// @dev Type identifier for the order data. This should be an EIP-712 typehash for EVM chains
        bytes32 orderDataType;
        /// @dev Arbitrary implementation-specific data
        /// Can be used to define tokens, amounts, destination chains, fees, settlement parameters,
        /// or any other order-type specific information
        bytes orderData;
    }

    /// @title XOnchainCrossChainOrder CrossChainOrder type
    /// @notice Standard order struct for user-opened orders, where the user is the one submitting the order creation transaction
    struct XOnchainCrossChainOrder {
        /// @dev The timestamp by which the order must be filled on the destination chain
        uint32 fillDeadline;
        /// @dev Type identifier for the order data. This should be an EIP-712 typehash for EVM chains
        bytes32 orderDataType;
        /// @dev Arbitrary implementation-specific data
        /// Can be used to define tokens, amounts, destination chains, fees, settlement parameters,
        /// or any other order-type specific information
        bytes orderData;
    }

    /// @title XResolvedCrossChainOrder type
    /// @notice An implementation-generic representation of an order intended for filler consumption
    /// @dev Defines all requirements for filling an order by unbundling the implementation-specific orderData.
    /// @dev Intended to improve integration generalization by allowing fillers to compute the exact input and output information of any order
    struct XResolvedCrossChainOrder {
        /// @dev The address of the user who is initiating the transfer
        bytes32 user;
        /// @dev The domain of the origin chain
        string domain;
        /// @dev The timestamp by which the order must be opened
        uint32 openDeadline;
        /// @dev The timestamp by which the order must be filled on the destination chain(s)
        uint32 fillDeadline;
        /// @dev The unique identifier for this order within this settlement system
        bytes32 orderId;
        /// @dev The max outputs that the filler will send. It's possible the actual amount depends on the state of the destination
        ///      chain (destination dutch auction, for instance), so these outputs should be considered a cap on filler liabilities.
        XOutput[] maxSpent;
        /// @dev The minimum outputs that must be given to the filler as part of order settlement. Similar to maxSpent, it's possible
        ///      that special order types may not be able to guarantee the exact amount at open time, so this should be considered
        ///      a floor on filler receipts. Setting the `recipient` of an `Output` to address(0) indicates that the filler is not
        ///      known when creating this order.
        XOutput[] minReceived;
        /// @dev Each instruction in this array is parameterizes a single leg of the fill. This provides the filler with the information
        ///      necessary to perform the fill on the destination(s).
        XFillInstruction[] fillInstructions;
    }

    /// @notice Tokens that must be received for a valid order fulfillment
    struct XOutput {
        /// @dev The address of the token on the destination chain
        /// @dev bytes32(0) used as a sentinel for the native token
        bytes32 token;
        /// @dev The amount of the token to be sent
        uint256 amount;
        /// @dev The address to receive the output tokens
        bytes32 recipient;
        /// @dev The destination chain for this output
        string domain;
    }

    /// @title FillInstruction type
    /// @notice Instructions to parameterize each leg of the fill
    /// @dev Provides all the origin-generated information required to produce a valid fill leg
    struct XFillInstruction {
        /// @dev The domain that this instruction is intended to be filled on
        string destinationDomain;
        /// @dev The address that the instruction is intended to be filled on
        bytes32 destinationSettler;
        /// @dev The data generated on the origin chain needed by the destinationSettler to process the fill
        bytes originData;
    }

    /// @notice Signals that an order has been opened
    /// @param orderId a unique order identifier within this settlement system
    /// @param resolvedOrder resolved order that would be returned by resolve if called instead of Open
    event XOpen(bytes32 indexed orderId, XResolvedCrossChainOrder resolvedOrder);
}
