// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AvailEscrow} from "../src/AvailEscrow.sol";
import {ICreateX} from "../src/interfaces/ICreateX.sol";

/// @title DeployAvailEscrow
/// @notice Deterministic deployment of AvailEscrow (UUPS proxy) via CreateX using CREATE2.
///         Each deployer gets a unique address for the same salt.
///
/// @dev Usage:
///   forge script script/DeployAvailEscrow.s.sol:DeployAvailEscrow \
///     --rpc-url $RPC_URL --broadcast --verify
///
///   Required env vars:
///     PRIVATE_KEY              - deployer EOA
///     ESCROW_OWNER             - contract owner (multisig in prod)
///     GLOBAL_UNLOCK_TIMEOUT    - seconds (default: 3600)
///     DEPLOY_SALT              - optional, defaults to keccak256("avail-escrow-v1")
contract DeployAvailEscrow is Script {
    ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    bytes32 public constant DEFAULT_SALT = keccak256("avail-escrow-v1.0.0");

    function run() external returns (address proxy) {
        address owner = _getOwner();
        uint256 unlockTimeout = _getUnlockTimeout();
        
        vm.startBroadcast();
        
        bytes32 salt = _getSalt();
        bytes32 proxySalt = keccak256(abi.encodePacked(salt, "proxy"));

        console.log("Owner:", owner);
        console.log("Unlock timeout:", unlockTimeout);
        console.log("Salt (impl):", vm.toString(salt));
        console.log("Salt (proxy):", vm.toString(proxySalt));

        // Deploy implementation
        bytes memory implInitCode = type(AvailEscrow).creationCode;
        bytes32 implInitCodeHash = keccak256(implInitCode);
        address expectedImpl = CREATEX.computeCreate2Address(keccak256(abi.encode(salt)), implInitCodeHash);
        console.log("Expected implementation:", expectedImpl);

        // Deploy proxy
        bytes memory initData = abi.encodeCall(AvailEscrow.initialize, (owner, unlockTimeout));
        bytes memory proxyInitCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(expectedImpl, initData));
        bytes32 proxyInitCodeHash = keccak256(proxyInitCode);
        address expectedProxy = CREATEX.computeCreate2Address(keccak256(abi.encode(proxySalt)), proxyInitCodeHash);
        console.log("Expected proxy:", expectedProxy);

        // Deploy implementation
        address implementation = CREATEX.deployCreate2(salt, implInitCode);
        console.log("Implementation:", implementation);
        require(implementation == expectedImpl, "Implementation address mismatch");

        // Deploy proxy
        proxy = CREATEX.deployCreate2(proxySalt, proxyInitCode);
        console.log("Proxy:", proxy);
        require(proxy == expectedProxy, "Proxy address mismatch");

        vm.stopBroadcast();

        console.log("DEPLOYED_ADDRESS:", proxy);

        // Verify on-chain state
        AvailEscrow escrow = AvailEscrow(payable(proxy));
        require(escrow.owner() == owner, "owner mismatch");
        require(escrow.globalUnlockTimeout() == unlockTimeout, "timeout mismatch");
    }

    function preview(address owner) external view returns (address impl, address proxy) {
        uint256 unlockTimeout = _getUnlockTimeout();
        bytes32 salt = _getSalt();
        bytes32 proxySalt = keccak256(abi.encodePacked(salt, "proxy"));

        // Expected implementation address
        impl = CREATEX.computeCreate2Address(salt, keccak256(type(AvailEscrow).creationCode));

        // Expected proxy address
        bytes memory initData = abi.encodeCall(AvailEscrow.initialize, (owner, unlockTimeout));
        bytes memory proxyInitCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData));
        proxy = CREATEX.computeCreate2Address(proxySalt, keccak256(proxyInitCode));

        console.log("Owner:", owner);
        console.log("Unlock timeout:", unlockTimeout);
        console.log("Expected Implementation:", impl);
        console.log("Expected Proxy:", proxy);
    }

    function _getSalt() internal view returns (bytes32) {
        try vm.envBytes32("DEPLOY_SALT") returns (bytes32 envSalt) {
            return envSalt;
        } catch {
            return DEFAULT_SALT;
        }
    }

    function _getOwner() internal view returns (address) {
        try vm.envAddress("ESCROW_OWNER") returns (address envOwner) {
            return envOwner;
        } catch {
            return msg.sender;
        }
    }

    function _getUnlockTimeout() internal view returns (uint256) {
        try vm.envUint("GLOBAL_UNLOCK_TIMEOUT") returns (uint256 envTimeout) {
            return envTimeout;
        } catch {
            return 3600; // 1 hour default
        }
    }
}
