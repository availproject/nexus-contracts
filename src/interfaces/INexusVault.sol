// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;
import {INexusSettler} from "../NexusSettler.sol";

interface INexusVault {
    struct SettlementInstruction {
        bytes32 token;
        uint256 amount;
        bytes32 destination;
    }

    function lock(INexusSettler.Lock calldata lock) external;

    function settle(SettlementInstruction[] calldata instructions) external;
}
