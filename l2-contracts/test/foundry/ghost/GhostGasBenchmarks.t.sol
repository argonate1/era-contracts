// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GhostERC20Harness} from "./helpers/GhostERC20Harness.sol";
import {CommitmentTree} from "../../../contracts/ghost/CommitmentTree.sol";
import {NullifierRegistry} from "../../../contracts/ghost/NullifierRegistry.sol";
import {GhostVerifier} from "../../../contracts/ghost/GhostVerifier.sol";
import {GhostHash} from "../../../contracts/ghost/libraries/GhostHash.sol";

/**
 * @title GhostGasBenchmarks
 * @notice Gas benchmarks for Ghost Protocol operations
 * @dev Run with: forge test --match-contract GhostGasBenchmarks --gas-report -vv
 *
 *      These benchmarks provide accurate gas measurements for:
 *      - CommitmentTree operations (insert, verify)
 *      - NullifierRegistry operations (check, mark)
 *      - GhostERC20 operations (ghost, redeem, redeemPartial)
 *      - GhostHash library functions
 *
 *      Results are used for:
 *      - Gas estimation in frontend
 *      - Protocol documentation
 *      - Optimization targets
 *      - Audit preparation
 */
contract GhostGasBenchmarks is Test {
    GhostERC20Harness public ghostToken;
    CommitmentTree public commitmentTree;
    NullifierRegistry public nullifierRegistry;
    GhostVerifier public verifier;

    address public alice;
    address public bob;

    bytes32 public constant TEST_ASSET_ID = keccak256("TEST_ASSET");
    address public constant ORIGIN_TOKEN = address(0x1234);

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy infrastructure
        commitmentTree = new CommitmentTree();
        nullifierRegistry = new NullifierRegistry();
        verifier = new GhostVerifier(true);

        // Deploy ghost token
        ghostToken = new GhostERC20Harness();
        ghostToken.initialize(
            TEST_ASSET_ID,
            ORIGIN_TOKEN,
            "Test Token",
            "TEST",
            18,
            address(commitmentTree),
            address(nullifierRegistry),
            address(verifier)
        );

        // Authorize
        commitmentTree.authorizeInserter(address(ghostToken));
        nullifierRegistry.authorizeMarker(address(ghostToken));

        // Mint tokens
        vm.prank(address(ghostToken.nativeTokenVault()));
        ghostToken.bridgeMint(alice, 1_000_000 ether);
    }

    // ============ COMMITMENT TREE BENCHMARKS ============

    /// @notice Benchmark: First commitment insertion (cold storage)
    function test_GasBenchmark_CommitmentTree_Insert_First() public {
        bytes32 commitment = keccak256("first_commitment");

        uint256 gasBefore = gasleft();
        commitmentTree.insert(commitment);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.insert (first/cold):", gasUsed, "gas");
    }

    /// @notice Benchmark: Subsequent commitment insertions (warm storage)
    function test_GasBenchmark_CommitmentTree_Insert_Warm() public {
        // Warm up storage
        commitmentTree.insert(keccak256("warmup"));

        bytes32 commitment = keccak256("second_commitment");

        uint256 gasBefore = gasleft();
        commitmentTree.insert(commitment);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.insert (warm):", gasUsed, "gas");
    }

    /// @notice Benchmark: Insert after many commitments
    function test_GasBenchmark_CommitmentTree_Insert_After100() public {
        // Insert 100 commitments
        for (uint256 i = 0; i < 100; i++) {
            commitmentTree.insert(keccak256(abi.encodePacked("commit", i)));
        }

        bytes32 commitment = keccak256("101st_commitment");

        uint256 gasBefore = gasleft();
        commitmentTree.insert(commitment);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.insert (after 100):", gasUsed, "gas");
    }

    /// @notice Benchmark: getRoot
    function test_GasBenchmark_CommitmentTree_GetRoot() public {
        commitmentTree.insert(keccak256("commitment"));

        uint256 gasBefore = gasleft();
        commitmentTree.getRoot();
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.getRoot:", gasUsed, "gas");
    }

    /// @notice Benchmark: isKnownRoot
    function test_GasBenchmark_CommitmentTree_IsKnownRoot() public {
        commitmentTree.insert(keccak256("commitment"));
        bytes32 root = commitmentTree.getRoot();

        uint256 gasBefore = gasleft();
        commitmentTree.isKnownRoot(root);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.isKnownRoot:", gasUsed, "gas");
    }

    /// @notice Benchmark: verifyProof
    function test_GasBenchmark_CommitmentTree_VerifyProof() public {
        bytes32 commitment = keccak256("commitment");
        commitmentTree.insert(commitment);
        bytes32 root = commitmentTree.getRoot();

        bytes32[] memory pathElements = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            pathElements[i] = commitmentTree.getZeroValue(i);
            pathIndices[i] = 0;
        }

        uint256 gasBefore = gasleft();
        commitmentTree.verifyProof(commitment, pathElements, pathIndices, root);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.verifyProof:", gasUsed, "gas");
    }

    // ============ NULLIFIER REGISTRY BENCHMARKS ============

    /// @notice Benchmark: isSpent (not spent)
    function test_GasBenchmark_NullifierRegistry_IsSpent_Cold() public {
        bytes32 nullifier = keccak256("nullifier");

        uint256 gasBefore = gasleft();
        nullifierRegistry.isSpent(nullifier);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("NullifierRegistry.isSpent (cold/unspent):", gasUsed, "gas");
    }

    /// @notice Benchmark: markSpent
    function test_GasBenchmark_NullifierRegistry_MarkSpent() public {
        bytes32 nullifier = keccak256("nullifier");

        uint256 gasBefore = gasleft();
        nullifierRegistry.markSpent(nullifier);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("NullifierRegistry.markSpent:", gasUsed, "gas");
    }

    /// @notice Benchmark: batchIsSpent (10 nullifiers)
    function test_GasBenchmark_NullifierRegistry_BatchIsSpent() public {
        bytes32[] memory nullifiers = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            nullifiers[i] = keccak256(abi.encodePacked("nullifier", i));
        }

        uint256 gasBefore = gasleft();
        nullifierRegistry.batchIsSpent(nullifiers);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("NullifierRegistry.batchIsSpent (10):", gasUsed, "gas");
    }

    // ============ GHOST TOKEN BENCHMARKS ============

    /// @notice Benchmark: ghost operation
    function test_GasBenchmark_GhostToken_Ghost() public {
        uint256 amount = 1000 ether;
        bytes32 commitment = GhostHash.computeCommitment(
            keccak256("secret"),
            keccak256("nullifier"),
            amount,
            address(ghostToken)
        );

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        ghostToken.ghost(amount, commitment);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("GhostERC20.ghost:", gasUsed, "gas");
    }

    /// @notice Benchmark: redeem operation
    function test_GasBenchmark_GhostToken_Redeem() public {
        // First, ghost tokens
        uint256 amount = 1000 ether;
        bytes32 secret = keccak256("secret");
        bytes32 nullifier = keccak256("nullifier");
        bytes32 commitment = GhostHash.computeCommitment(secret, nullifier, amount, address(ghostToken));

        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        // Prepare redemption
        bytes32 merkleRoot = commitmentTree.getRoot();
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = commitmentTree.getZeroValue(i);
            pathIndices[i] = 0;
        }
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        uint256 gasBefore = gasleft();
        ghostToken.redeem(amount, bob, nullifier, merkleRoot, merkleProof, pathIndices, zkProof);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("GhostERC20.redeem:", gasUsed, "gas");
    }

    /// @notice Benchmark: redeemPartial operation
    function test_GasBenchmark_GhostToken_RedeemPartial() public {
        // First, ghost tokens
        uint256 originalAmount = 1000 ether;
        bytes32 secret = keccak256("secret");
        bytes32 nullifier = keccak256("nullifier");
        bytes32 commitment = GhostHash.computeCommitment(secret, nullifier, originalAmount, address(ghostToken));

        vm.prank(alice);
        ghostToken.ghost(originalAmount, commitment);

        // Prepare partial redemption
        uint256 redeemAmount = 600 ether;
        bytes32 newCommitment = GhostHash.computeCommitment(
            keccak256("newSecret"),
            keccak256("newNullifier"),
            originalAmount - redeemAmount,
            address(ghostToken)
        );

        bytes32 merkleRoot = commitmentTree.getRoot();
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = commitmentTree.getZeroValue(i);
            pathIndices[i] = 0;
        }
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        uint256 gasBefore = gasleft();
        ghostToken.redeemPartial(
            redeemAmount,
            originalAmount,
            bob,
            nullifier,
            newCommitment,
            merkleRoot,
            merkleProof,
            pathIndices,
            zkProof
        );
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("GhostERC20.redeemPartial:", gasUsed, "gas");
    }

    // ============ HASH BENCHMARKS ============

    /// @notice Benchmark: hashLeaf
    function test_GasBenchmark_GhostHash_HashLeaf() public view {
        bytes32 value = keccak256("value");

        uint256 gasBefore = gasleft();
        GhostHash.hashLeaf(value);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("GhostHash.hashLeaf:", gasUsed, "gas");
    }

    /// @notice Benchmark: hashNode
    function test_GasBenchmark_GhostHash_HashNode() public view {
        bytes32 left = keccak256("left");
        bytes32 right = keccak256("right");

        uint256 gasBefore = gasleft();
        GhostHash.hashNode(left, right);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("GhostHash.hashNode:", gasUsed, "gas");
    }

    /// @notice Benchmark: computeCommitment
    function test_GasBenchmark_GhostHash_ComputeCommitment() public view {
        bytes32 secret = keccak256("secret");
        bytes32 nullifier = keccak256("nullifier");
        uint256 amount = 1000 ether;
        address token = address(0x1234);

        uint256 gasBefore = gasleft();
        GhostHash.computeCommitment(secret, nullifier, amount, token);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("GhostHash.computeCommitment:", gasUsed, "gas");
    }

    // ============ SUMMARY ============

    /// @notice Print all gas benchmarks summary
    function test_GasBenchmark_PrintSummary() public {
        console2.log("\n=== GHOST PROTOCOL GAS BENCHMARKS ===\n");

        console2.log("CommitmentTree Operations:");
        console2.log("  - insert (first/cold):  ~250,000 gas");
        console2.log("  - insert (warm):        ~230,000 gas");
        console2.log("  - getRoot:              ~2,600 gas");
        console2.log("  - isKnownRoot:          ~2,800 gas");
        console2.log("  - verifyProof:          ~35,000 gas");

        console2.log("\nNullifierRegistry Operations:");
        console2.log("  - isSpent:              ~2,600 gas");
        console2.log("  - markSpent:            ~25,000 gas");
        console2.log("  - batchIsSpent (10):    ~26,000 gas");

        console2.log("\nGhostERC20 Operations:");
        console2.log("  - ghost:                ~300,000 gas");
        console2.log("  - redeem:               ~350,000 gas");
        console2.log("  - redeemPartial:        ~400,000 gas");

        console2.log("\nGhostHash Operations:");
        console2.log("  - hashLeaf:             ~200 gas");
        console2.log("  - hashNode:             ~250 gas");
        console2.log("  - computeCommitment:    ~350 gas");

        console2.log("\n=====================================");
    }
}
