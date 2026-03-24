// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
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
        // Deploy with deployer as temporary settler, will update to actual settler after
        NexusEscrow escrow = new NexusEscrow(deployer);
        console.log("NexusEscrow deployed at: ", address(escrow));
        
        // Deploy NexusSettler with escrow address
        console.log("\nDeploying NexusSettler...");
        NexusSettler settler = new NexusSettler(address(escrow));
        console.log("NexusSettler deployed at: ", address(settler));
        
        // Update escrow settler to actual settler address
        // This requires the escrow to have a setter function
        console.log("\nUpdating NexusEscrow settler...");
        escrow.updateSettler(address(settler));
        console.log("NexusEscrow settler updated to: ", address(settler));

        vm.stopBroadcast();

        // Deployment summary
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Chain ID: ", block.chainid);
        console.log("NexusEscrow: ", address(escrow));
        console.log("NexusSettler: ", address(settler));
        console.log("===========================");

        // Verification commands
        console.log("\n=== VERIFICATION COMMANDS ===");
        console.log("To verify NexusEscrow:");
        console.log("forge verify-contract ", address(escrow), " src/NexusEscrow.sol:NexusEscrow");
        console.log("--chain-id ", block.chainid);

        console.log("\nTo verify NexusSettler:");
        console.log("forge verify-contract ", address(settler), " src/NexusSettler.sol:NexusSettler");
        console.log("--chain-id ", block.chainid);
        console.log("=============================");
    }
}
