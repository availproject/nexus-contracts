// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV4Router} from "../src/routers/UniswapV4Router.sol";

contract DeploySwapRouterScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address universalRouterAddress = vm.envAddress("UNIVERSAL_ROUTER_ADDRESS");
        address permit2Address = vm.envAddress("PERMIT2_ADDRESS");

        console.log("=== UNISWAP V4 ROUTER DEPLOYMENT ===");
        console.log("Deployer:", deployer);
        console.log("Balance: ", deployer.balance);
        console.log("Chain ID: ", block.chainid);
        console.log("Block number: ", block.number);
        console.log("UniversalRouter: ", universalRouterAddress);
        console.log("Permit2: ", permit2Address);
        console.log("====================================");

        vm.startBroadcast(deployerPrivateKey);

        console.log("\nDeploying UniswapV4Router...");
        UniswapV4Router router = new UniswapV4Router(universalRouterAddress, permit2Address);
        console.log("UniswapV4Router deployed at: ", address(router));

        vm.stopBroadcast();

        // Deployment summary
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Chain ID: ", block.chainid);
        console.log("UniswapV4Router: ", address(router));
        console.log("===========================");

        // Verification command
        console.log("\n=== VERIFICATION COMMAND ===");
        console.log("To verify UniswapV4Router:");
        console.log("forge verify-contract ", address(router), " src/routers/UniswapV4Router.sol:UniswapV4Router");
        console.log("--chain-id ", block.chainid);
        console.log("============================");
    }
}
