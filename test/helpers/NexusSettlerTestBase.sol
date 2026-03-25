// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "../../src/NexusSettler.sol";
import "../../src/interfaces/INexusSettler.sol";

/**
 * @title NexusSettlerTestBase
 * @notice Shared test helpers for NexusSettler fuzz and unit tests
 * @dev All helper functions are internal for inheritance by test contracts
 */
abstract contract NexusSettlerTestBase is Test {
    NexusSettler public nexusSettler;
    address public escrow;
    address public user;
    uint256 public userPrivateKey;

    /// Contract deployment with escrow mock
    function setUp() public virtual {
        escrow = makeAddr("escrow");
        (user, userPrivateKey) = makeAddrAndKey("user");
        nexusSettler = new NexusSettler(escrow);
    }

    /// Computes EIP-712 digest for signing
    function _computeDigest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NexusSettler")),
                keccak256(bytes("2")),
                block.chainid,
                address(nexusSettler)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    /// Etches minimal runtime code at an address so Address.functionCall succeeds
    function _etchDummy(address target) internal {
        // STOP opcode — accepts any call, returns nothing
        vm.etch(target, hex"00");
    }

    /// Creates single-node test path
    function _createTestPath() internal returns (INexusSettler.IntendNode[] memory) {
        address target = address(0x1234);
        _etchDummy(target);
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](1);
        path[0] = INexusSettler.IntendNode({
            next: bytes32(0), target: target, data: abi.encodeWithSignature("dummy()")
        });
        return path;
    }

    /// Creates multi-node path with linked next pointers
    function _createMultiNodePath(uint256 count) internal returns (INexusSettler.IntendNode[] memory) {
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](count);
        for (uint256 i = 0; i < count; i++) {
            address target = address(uint160(0x1000 + i));
            _etchDummy(target);
            path[i] = INexusSettler.IntendNode({
                next: i + 1 < count ? keccak256(abi.encode(path[i + 1])) : bytes32(0),
                target: target,
                data: abi.encodeWithSignature("action%i()", i)
            });
        }
        return path;
    }

    /// Helper to build RootNode
    function _createRootNode(bytes32 s, bytes32 d, bytes32 o) internal pure returns (INexusSettler.RootNode memory) {
        return INexusSettler.RootNode({s: s, d: d, o: o});
    }

    /// Helper to build TargetNode with perfect hash data
    function _createTargetNode(INexusSettler.TargetType targetType, uint16[] memory chainIds, bytes32[] memory hashes)
        internal
        pure
        returns (INexusSettler.TargetNode memory)
    {
        require(chainIds.length == hashes.length, "length mismatch");
        uint16 k = uint16(chainIds.length);

        // Find collision-free seed
        uint16 seed;
        bool found;
        for (uint16 s = 0; s < 65535; s++) {
            bool collision = false;
            for (uint256 i = 0; i < k && !collision; i++) {
                uint256 slotI = uint256(keccak256(abi.encodePacked(chainIds[i], s))) % k;
                for (uint256 j = i + 1; j < k && !collision; j++) {
                    uint256 slotJ = uint256(keccak256(abi.encodePacked(chainIds[j], s))) % k;
                    if (slotI == slotJ) collision = true;
                }
            }
            if (!collision) {
                seed = s;
                found = true;
                break;
            }
        }
        require(found, "no valid seed found");

        // Build perfect hash table
        bytes memory chainIdToNode = new bytes(4 + uint256(k) * 34);
        chainIdToNode[0] = bytes1(uint8(k >> 8));
        chainIdToNode[1] = bytes1(uint8(k));
        chainIdToNode[2] = bytes1(uint8(seed >> 8));
        chainIdToNode[3] = bytes1(uint8(seed));

        for (uint256 i = 0; i < k; i++) {
            uint256 slot = uint256(keccak256(abi.encodePacked(chainIds[i], seed))) % k;
            uint256 pos = 4 + slot * 34;
            chainIdToNode[pos] = bytes1(uint8(chainIds[i] >> 8));
            chainIdToNode[pos + 1] = bytes1(uint8(chainIds[i]));
            for (uint256 b = 0; b < 32; b++) {
                chainIdToNode[pos + 2 + b] = hashes[i][b];
            }
        }

        return INexusSettler.TargetNode({targetType: targetType, chainIdToNode: chainIdToNode});
    }

    /// Creates single-chain TargetNode (k=1)
    function _createSingleTargetNode(INexusSettler.TargetType targetType, uint16 chainId, bytes32 targetHash)
        internal
        pure
        returns (INexusSettler.TargetNode memory)
    {
        uint16[] memory chainIds = new uint16[](1);
        chainIds[0] = chainId;
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = targetHash;
        return _createTargetNode(targetType, chainIds, hashes);
    }

    /// Computes target node hash for testing
    function _getTargetNodeHash(bytes32 rootHash, bool isSource) internal pure returns (bytes32) {
        return isSource ? keccak256(abi.encode(rootHash, "source")) : keccak256(abi.encode(rootHash, "destination"));
    }

    /// Computes completion key for testing
    function _getCompletionKey(bytes32 rootHash, bytes32 targetNodeHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(rootHash, targetNodeHash));
    }
}
