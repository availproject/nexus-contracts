// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {INexusEscrow} from "./interfaces/INexusEscrow.sol";

/// @title NexusEscrow
/// @notice A simple escrow contract for holding tokens during cross-chain settlements
contract NexusEscrow is INexusEscrow {
    using SafeERC20 for IERC20;

    // TODO: access control
    function settle(Settlement[] calldata settlements) external {
        uint256 i;
        for (i = 0; i < settlements.length;) {
            Settlement memory settlement = settlements[i];
            IERC20 token = IERC20(address(bytes20(settlement.token)));
            address recipient = address(bytes20(settlement.recipient));
            token.safeTransfer(recipient, settlement.amount);
            unchecked {
                ++i;
            }
        }
    }
}
