// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NexusEscrow} from "../src/NexusEscrow.sol";
import {NexusSettler} from "../src/NexusSettler.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== NEXUS DEPLOYMENT ===");
        console.log("Deployer:", deployer);
        console.log("Balance: ", deployer.balance);
        console.log("Chain ID: ", block.chainid);
        console.log("Block number: ", block.number);
        console.log("========================");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy NexusEscrow first (settler will be set after settler deployment)
        console.log("\nDeploying NexusEscrow...");
        NexusEscrow escrow = new NexusEscrow(deployer);
        console.log("NexusEscrow deployed at: ", address(escrow));

        // Deploy NexusSettler implementation + proxy
        console.log("\nDeploying NexusSettler (UUPS proxy)...");
        NexusSettler settlerImpl = new NexusSettler();
        console.log("NexusSettler implementation: ", address(settlerImpl));

        ERC1967Proxy settlerProxy = new ERC1967Proxy(
            address(settlerImpl),
            abi.encodeCall(NexusSettler.initialize, (address(escrow), deployer))
        );
        NexusSettler settler = NexusSettler(address(settlerProxy));
        console.log("NexusSettler proxy: ", address(settler));

        // Update escrow settler to actual settler address
        console.log("\nUpdating NexusEscrow settler...");
        escrow.updateSettler(address(settler));
        console.log("NexusEscrow settler updated to: ", address(settler));

        vm.stopBroadcast();

        // Deployment summary
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Chain ID: ", block.chainid);
        console.log("NexusEscrow: ", address(escrow));
        console.log("NexusSettler (proxy): ", address(settler));
        console.log("NexusSettler (impl):  ", address(settlerImpl));
        console.log("===========================");
    }
}
