// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../mocks/MockAavePool.sol";
import "../mocks/MockAToken.sol";
import "../mocks/DirectSwapAaveExecutor.sol";
import "../../src/NexusSettler.sol";
import "../../src/interfaces/INexusSettler.sol";

// ============================================================================
// Mock ERC20 Token
// ============================================================================
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============================================================================
// Fair Aave Deposit Comparison Test
// ============================================================================
contract FairAaveDepositComparison is Test {
    NexusSettler public nexusSettler;
    DirectSwapAaveExecutor public directExecutor;
    MockAavePool public mockAavePool;
    MockAToken public mockAToken;
    MockERC20 public tokenB;

    address public escrow;

    uint256 constant INITIAL_BALANCE = 1000000e18;
    uint256 constant DEPOSIT_AMOUNT = 995e18;

    function setUp() public {
        escrow = makeAddr("escrow");
        nexusSettler = new NexusSettler(escrow);
        mockAavePool = new MockAavePool();

        // Deploy executor with dummy swap router (not used for deposit-only)
        directExecutor = new DirectSwapAaveExecutor(address(0), address(mockAavePool));

        tokenB = new MockERC20("Token B", "TKB");
        mockAToken = new MockAToken("Aave Token B", "aTKB");
        mockAToken.setMinter(address(mockAavePool));
        mockAavePool.setATokenForAsset(address(tokenB), address(mockAToken));
    }

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
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), DOMAIN_SEPARATOR, structHash));
    }

    function _executeProcessPIPath(
        bytes32 rootHash,
        INexusSettler.RootNode memory rootNode,
        bytes32 entryNodeHash,
        INexusSettler.IntendNode[] memory path,
        uint256 nonce
    ) internal {
        bytes memory chainIdToNode = new bytes(38);
        chainIdToNode[0] = bytes1(uint8(0));
        chainIdToNode[1] = bytes1(uint8(1));
        chainIdToNode[2] = bytes1(uint8(0));
        chainIdToNode[3] = bytes1(uint8(0));
        chainIdToNode[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNode[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNode[6 + i] = entryNodeHash[i];
        }

        INexusSettler.TargetNode memory targetNode =
            INexusSettler.TargetNode({targetType: INexusSettler.TargetType.Destination, chainIdToNode: chainIdToNode});
        
        nexusSettler.processPIPath(rootHash, rootNode, targetNode, path, nonce, false);
    }

    /**
     * @notice FAIR COMPARISON: Both approaches do EXACTLY the same operations
     *         through an intermediary contract.
     *
     * DIRECT APPROACH (via DirectSwapAaveExecutor.depositOnly):
     *   transferFrom(user, executor, amount) -> approve(pool, amount) -> supply(...)
     *
     * DAG APPROACH (via NexusSettler IntendNodes):
     *   transferFrom(user, settler, amount) -> approve(pool, amount) -> supply(...)
     *
     * The ONLY difference: DAG adds validation overhead (hash verification, chain ID check)
     */
    function testFairComparison_DepositOnly() public {
        // Snapshot for clean comparison
        uint256 state = vm.snapshot();

        // ============================================
        // DIRECT APPROACH (via executor contract)
        // Same 3 ops: pull -> approve -> supply
        // ============================================
        address fillerDirect = makeAddr("filler_direct");
        tokenB.mint(fillerDirect, INITIAL_BALANCE);

        vm.startPrank(fillerDirect);
        tokenB.approve(address(directExecutor), type(uint256).max);
        vm.stopPrank();

        vm.prank(fillerDirect);
        uint256 gasStartDirect = gasleft();
        directExecutor.depositOnly(address(tokenB), DEPOSIT_AMOUNT, fillerDirect);
        uint256 gasDirect = gasStartDirect - gasleft();

        // Store Direct result before revert
        uint256 directATokenBalance = mockAToken.balanceOf(fillerDirect);

        // ============================================
        // DAG APPROACH (2 steps + validation)
        // ============================================
        vm.revertTo(state);

        address fillerDag = makeAddr("filler_dag");
        uint256 fillerDagPrivateKey = 0xabcdef1234567890;
        tokenB.mint(fillerDag, INITIAL_BALANCE);

        // Setup approvals
        vm.startPrank(fillerDag);
        tokenB.approve(address(nexusSettler), type(uint256).max);
        vm.stopPrank();

        // Build path FIRST to compute proper hashes
        // Create 3-node path: EXACT same operations as Direct
        // pull -> approve aave pool -> supply
        INexusSettler.IntendNode[] memory path = new INexusSettler.IntendNode[](3);

        // Node 2: Deposit (Step 3 - supply does transferFrom internally)
        path[2] = INexusSettler.IntendNode({
            next: bytes32(0),
            target: address(mockAavePool),
            data: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", address(tokenB), DEPOSIT_AMOUNT, fillerDag, 0
            )
        });

        // Node 1: Approve Aave pool to pull tokens from settler (Step 2)
        path[1] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[2])),
            target: address(tokenB),
            data: abi.encodeWithSignature("approve(address,uint256)", address(mockAavePool), DEPOSIT_AMOUNT)
        });

        // Node 0: Pull tokens from filler to settler (Step 1)
        path[0] = INexusSettler.IntendNode({
            next: keccak256(abi.encode(path[1])),
            target: address(tokenB),
            data: abi.encodeWithSignature(
                "transferFrom(address,address,uint256)", fillerDag, address(nexusSettler), DEPOSIT_AMOUNT
            )
        });

        bytes32 entryNodeHash = keccak256(abi.encode(path[0]));

        // Create targetNode from entryNodeHash and compute proper d value
        bytes memory chainIdToNode = new bytes(38);
        chainIdToNode[0] = bytes1(uint8(0));
        chainIdToNode[1] = bytes1(uint8(1));
        chainIdToNode[2] = bytes1(uint8(0));
        chainIdToNode[3] = bytes1(uint8(0));
        chainIdToNode[4] = bytes1(uint8(uint16(block.chainid) >> 8));
        chainIdToNode[5] = bytes1(uint8(uint16(block.chainid)));
        for (uint256 i = 0; i < 32; i++) {
            chainIdToNode[6 + i] = entryNodeHash[i];
        }

        INexusSettler.TargetNode memory targetNode =
            INexusSettler.TargetNode({targetType: INexusSettler.TargetType.Destination, chainIdToNode: chainIdToNode});

        bytes32 d = keccak256(abi.encode(targetNode));
        bytes32 s = keccak256("source");
        bytes32 o = keccak256("offchain");
        uint256 nonce = 1;
        INexusSettler.RootNode memory rootNode = INexusSettler.RootNode({s: s, d: d, o: o});
        bytes32 rootHash = keccak256(abi.encode(rootNode, nonce));

        // Generate and verify signature
        bytes32 PI_TYPEHASH = keccak256("NexusPI(bytes32 rootHash,uint256 nonce)");
        bytes32 structHash = keccak256(abi.encode(PI_TYPEHASH, rootHash, nonce));
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s_sig) = vm.sign(fillerDagPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s_sig, v);

        // Create PI (this is setup, NOT measured in gas comparison)
        nexusSettler.createPI(rootHash, signature, nonce, rootNode);

        // Measure gas from THIS POINT (like we did for Direct)
        uint256 gasStartDag = gasleft();
        _executeProcessPIPath(rootHash, rootNode, entryNodeHash, path, nonce);
        uint256 gasDAG = gasStartDag - gasleft();

        // Store DAG result
        uint256 dagATokenBalance = mockAToken.balanceOf(fillerDag);

        // ============================================
        // COMPARISON OUTPUT
        // ============================================
        console2.log("\n========== FAIR COMPARISON: AAVE DEPOSIT ==========");
        console2.log("\nOperations performed (both approaches):");
        console2.log("  1. transferFrom(user, executor/settler, amount)");
        console2.log("  2. approve(aavePool, amount)");
        console2.log("  3. supply(token, amount, user, 0) [pool pulls via transferFrom]");
        console2.log("\nDirect Approach (via executor contract):");
        console2.log("  Gas used:", gasDirect);
        console2.log("  Steps: 3 (pull + approve + supply)");
        console2.log("  Validation overhead: NONE");

        console2.log("\nDAG Approach (via NexusSettler):");
        console2.log("  Gas used:", gasDAG);
        console2.log("  Steps: 3 (pull + approve + supply) + validation");
        console2.log("  Validation overhead:");
        console2.log("    - rootHash verification");
        console2.log("    - targetNodeHash verification");
        console2.log("    - chain ID validation");
        console2.log("    - path traversal logic");
        console2.log("    - completion tracking");

        console2.log("\nResults:");
        console2.log("  DAG Overhead (gas):", gasDAG - gasDirect);
        console2.log("  DAG Overhead (%):", ((gasDAG - gasDirect) * 100) / gasDirect, "%");
        console2.log("  Cost per validation step:", (gasDAG - gasDirect) / 5, "gas"); // 5 validation operations

        // Verify both achieved same result
        assertEq(directATokenBalance, DEPOSIT_AMOUNT, "Direct: Filler should have aTokens");
        assertEq(dagATokenBalance, DEPOSIT_AMOUNT, "DAG: Filler should have aTokens");

        // DAG should have overhead
        assertGt(gasDAG, gasDirect, "DAG must have validation overhead");
    }
}
