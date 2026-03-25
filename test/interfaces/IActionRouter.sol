// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

interface IActionRouter {
    enum ActionType {
        PERMIT,
        PERMIT2,
        TRANSFER,
        BRIDGE,
        SWAP,
        BRIDGE_AND_SWAP
    }

    struct Action {
        ActionType actionType;
        string target;
        bytes callData;
        uint256 value;
    }

    //The router currently uses users balance, and assume the router is approved. Change this to be able to use solvers balance.
    function execute(Action calldata action, bytes calldata data) external returns (bytes memory);
}
