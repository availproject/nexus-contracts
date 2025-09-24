// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

interface INexusEscrow {
    struct Settlement {
        bytes32 token;
        bytes32 recipient;
        uint256 amount;
    }

    function settle(Settlement[] calldata settlements) external;
}
