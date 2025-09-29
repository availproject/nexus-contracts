// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

interface INexusSettler {
    enum ActionType {
        PERMIT,
        PERMIT2,
        TRANSFER,
        BRIDGE,
        SWAP,
        BRIDGE_AND_SWAP
    }

    struct Lock {
        bytes32 source;
        bytes32 token;
        uint256 amount;
    }

    struct Fund {
        bytes32 recipient;
        bytes32 token;
        uint256 amount;
    }

    struct Action {
        ActionType actionType;
        string target;
        bytes callData;
        uint256 value;
    }

    struct Resource {
        string domain;
        bytes32 token;
        uint256 amount;
        bytes32 recipient;
    }

    /// Conditions are actions that must be successfully executed before other actions can be executed
    /// Locks are actions that lock funds for some actions
    /// Funds are actions that provide funds for some actions
    /// Actions are arbitrary actions that perform some operation
    /// Outputs are resources expected to be produced by the actions
    struct Actions {
        string domain;
        bytes32 settler;
        Action[] conditions;
        Lock[] locks;
        Fund[] funds;
        Action[] actions;
    }

    struct Intent {
        string domain;
        Actions[] batches;
        bytes32 sender;
        bytes32 recipient;
        uint256 nonce;
        Resource[] inputs;
        Resource[] outputs;
    }

    error InvalidOrderDataType();
    error InvalidDomain();
    error InvalidLock();
    error InvalidOutput();
    error InvalidOrderId();
    error InvalidSender();
    error OrderSent();
    error OrderFilled();

    event Executed(bytes32 indexed orderId, ActionType indexed actionType, Action action);
    event Filled(bytes32 indexed orderId);
}
