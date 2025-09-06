// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

interface INexusSettler {
    enum ActionType {
        LOCK,
        TRANSFER,
        SWAP
    }

    struct Venue {
        string target;
        bytes callData;
        uint256 value;
    }

    struct Action {
        ActionType actionType;
        string domain;
        bytes32 settler;
        Venue[] venue;
    }

    struct Resource {
        bytes32 token;
        uint256 amount;
        bytes32 recipient;
        string domain;
    }

    struct Intent {
        Action[] actions;
        Resource[] locks;
        Resource[] outputs;
        bytes32 sender;
        bytes32 recipient;
        string domain;
        uint256 nonce;
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
