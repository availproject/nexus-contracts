// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {INexusSettler} from "./INexusSettler.sol";

interface IActionRouter {
    //The router currently uses users balance, and assume the router is approved. Change this to be able to use solvers balance.
    function execute(
        INexusSettler.Action calldata action,
        bytes calldata data
    ) external returns (bytes memory);
}
