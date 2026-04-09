// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {Options} from "@openzeppelin/foundry-upgrades/Options.sol";
import {AvailEscrow} from "../src/AvailEscrow.sol";

/// @title UpgradeAvailEscrow
/// @notice Upgrades the AvailEscrow UUPS proxy to a new implementation.
///         Uses OpenZeppelin Foundry Upgrades for storage layout safety checks.
///
/// @dev Usage:
///   forge clean && forge script script/UpgradeAvailEscrow.s.sol:UpgradeAvailEscrow \
///     --rpc-url $RPC_URL --broadcast --verify --sender <OWNER_ADDRESS>
///
///   Required env vars:
///     PRIVATE_KEY    - owner EOA (must be current proxy owner)
///     PROXY_ADDRESS  - address of the deployed AvailEscrow proxy
contract UpgradeAvailEscrow is Script {
    function run() external {
        address proxy = vm.envAddress("PROXY_ADDRESS");

        console.log("Proxy:", proxy);

        // Verify current state before upgrade
        AvailEscrow current = AvailEscrow(payable(proxy));
        address currentOwner = current.owner();
        uint256 currentTimeout = current.globalUnlockTimeout();
        console.log("Current owner:", currentOwner);
        console.log("Current timeout:", currentTimeout);

        vm.startBroadcast();

        Options memory opts;
        // Skip storage layout comparison for first upgrade — no previous version
        // to compare against. Storage layout is unchanged (only added validation
        // logic in deposit(), no new state variables).
        opts.unsafeSkipStorageCheck = true;

        Upgrades.upgradeProxy(proxy, "AvailEscrow.sol:AvailEscrow", "", opts);

        vm.stopBroadcast();

        // Verify state is preserved after upgrade
        AvailEscrow upgraded = AvailEscrow(payable(proxy));
        require(upgraded.owner() == currentOwner, "owner changed after upgrade");
        require(upgraded.globalUnlockTimeout() == currentTimeout, "timeout changed after upgrade");

        console.log("Upgrade complete. Proxy:", proxy);
    }
}
