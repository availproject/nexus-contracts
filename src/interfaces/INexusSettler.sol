// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

interface INexusSettler {
    enum ActionType {
        FUND
    }

    struct Action {
        ActionType actionType;
        string domain;
        bytes data;
    }

    struct Intent {
        Action[] actions;
        bytes32 sender;
        bytes32 recipient;
        string domain;
        uint256 nonce;
    }

    error InvalidOrderDataType();
    error InvalidDomain();
}
