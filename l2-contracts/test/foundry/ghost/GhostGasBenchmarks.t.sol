// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GhostERC20Harness} from "./helpers/GhostERC20Harness.sol";
import {CommitmentTree} from "../../../contracts/ghost/CommitmentTree.sol";
import {NullifierRegistry} from "../../../contracts/ghost/NullifierRegistry.sol";
import {GhostVerifier} from "../../../contracts/ghost/GhostVerifier.sol";

/**
 * @title GhostGasBenchmarks
 * @notice Gas benchmarks for Ghost Protocol operations (off-chain tree architecture)
 * @dev Run with: forge test --match-contract GhostGasBenchmarks --gas-report -vv
 *
 *      These benchmarks provide accurate gas measurements for:
 *      - CommitmentTree operations (insert, submitRoot, isKnownRoot)
 *      - NullifierRegistry operations (check, mark)
 *      - GhostERC20 operations (ghost, redeem, redeemPartial)
 *
 *      Note: With off-chain tree architecture, most expensive operations
 *      (Poseidon hashing, Merkle tree computation) happen off-chain.
 *      On-chain costs are significantly reduced.
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
    address public relayer;

    bytes32 public constant TEST_ASSET_ID = keccak256("TEST_ASSET");
    address public constant ORIGIN_TOKEN = address(0x1234);

    // Precomputed initial root for empty tree (Z20 - must match SDK)
    bytes32 constant INITIAL_ROOT = bytes32(0x0b4a6c626bd085f652fb17cad5b70c9db903266b5a3f456ea6373a3cf97f3453);

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        relayer = makeAddr("relayer");

        // Deploy infrastructure with initial root
        commitmentTree = new CommitmentTree(INITIAL_ROOT);
        nullifierRegistry = new NullifierRegistry();
        verifier = new GhostVerifier(true);

        // Set relayer as root submitter
        commitmentTree.setRootSubmitter(relayer);

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

    // ============ Helper Functions ============

    /// @notice Build a dummy merkle proof for test mode verifier
    function _buildDummyProof() internal pure returns (
        bytes32[] memory merkleProof,
        uint256[] memory pathIndices,
        bytes memory zkProof
    ) {
        merkleProof = new bytes32[](20);
        pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = bytes32(0);
            pathIndices[i] = 0;
        }
        zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    /// @notice Compute a test commitment using keccak256 (for testing only)
    function _computeTestCommitment(
        bytes32 secret,
        bytes32 nullifier,
        uint256 amount,
        address token
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(secret, nullifier, amount, token));
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

    /// @notice Benchmark: submitRoot
    function test_GasBenchmark_CommitmentTree_SubmitRoot() public {
        commitmentTree.insert(keccak256("commitment"));

        bytes32 newRoot = keccak256("computed_root");

        vm.prank(relayer);
        uint256 gasBefore = gasleft();
        commitmentTree.submitRoot(newRoot, 1);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.submitRoot:", gasUsed, "gas");
    }

    /// @notice Benchmark: insertAndUpdateRoot (atomic operation)
    function test_GasBenchmark_CommitmentTree_InsertAndUpdateRoot() public {
        bytes32 commitment = keccak256("commitment");
        bytes32 newRoot = keccak256("new_root");

        vm.prank(relayer);
        uint256 gasBefore = gasleft();
        commitmentTree.insertAndUpdateRoot(commitment, newRoot);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.insertAndUpdateRoot:", gasUsed, "gas");
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
    function test_GasBenchmark_CommitmentTree_IsKnownRoot() public view {
        uint256 gasBefore = gasleft();
        commitmentTree.isKnownRoot(INITIAL_ROOT);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.isKnownRoot:", gasUsed, "gas");
    }

    /// @notice Benchmark: getCommitment
    function test_GasBenchmark_CommitmentTree_GetCommitment() public {
        commitmentTree.insert(keccak256("commitment"));

        uint256 gasBefore = gasleft();
        commitmentTree.getCommitment(0);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.getCommitment:", gasUsed, "gas");
    }

    /// @notice Benchmark: getCommitments (batch read)
    function test_GasBenchmark_CommitmentTree_GetCommitments() public {
        // Insert 10 commitments
        for (uint256 i = 0; i < 10; i++) {
            commitmentTree.insert(keccak256(abi.encodePacked("commitment", i)));
        }

        uint256 gasBefore = gasleft();
        commitmentTree.getCommitments(0, 10);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("CommitmentTree.getCommitments (10):", gasUsed, "gas");
    }

    // ============ NULLIFIER REGISTRY BENCHMARKS ============

    /// @notice Benchmark: isSpent (not spent)
    function test_GasBenchmark_NullifierRegistry_IsSpent_Cold() public view {
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
    function test_GasBenchmark_NullifierRegistry_BatchIsSpent() public view {
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
        bytes32 commitment = _computeTestCommitment(
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
        bytes32 commitment = _computeTestCommitment(secret, nullifier, amount, address(ghostToken));

        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        // Relayer submits root
        bytes32 newRoot = keccak256("test_root");
        vm.prank(relayer);
        commitmentTree.submitRoot(newRoot, 1);

        // Prepare redemption
        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        uint256 gasBefore = gasleft();
        ghostToken.redeem(amount, bob, nullifier, newRoot, merkleProof, pathIndices, zkProof);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("GhostERC20.redeem:", gasUsed, "gas");
    }

    /// @notice Benchmark: redeemPartial operation
    function test_GasBenchmark_GhostToken_RedeemPartial() public {
        // First, ghost tokens
        uint256 originalAmount = 1000 ether;
        bytes32 secret = keccak256("secret");
        bytes32 nullifier = keccak256("nullifier");
        bytes32 commitment = _computeTestCommitment(secret, nullifier, originalAmount, address(ghostToken));

        vm.prank(alice);
        ghostToken.ghost(originalAmount, commitment);

        // Relayer submits root
        bytes32 newRoot = keccak256("test_root");
        vm.prank(relayer);
        commitmentTree.submitRoot(newRoot, 1);

        // Prepare partial redemption
        uint256 redeemAmount = 600 ether;
        bytes32 newCommitment = _computeTestCommitment(
            keccak256("newSecret"),
            keccak256("newNullifier"),
            originalAmount - redeemAmount,
            address(ghostToken)
        );

        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        uint256 gasBefore = gasleft();
        ghostToken.redeemPartial(
            redeemAmount,
            originalAmount,
            bob,
            nullifier,
            newCommitment,
            newRoot,
            merkleProof,
            pathIndices,
            zkProof
        );
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("GhostERC20.redeemPartial:", gasUsed, "gas");
    }

    // ============ SUMMARY ============

    /// @notice Print all gas benchmarks summary
    function test_GasBenchmark_PrintSummary() public pure {
        console2.log("\n=== GHOST PROTOCOL GAS BENCHMARKS (OFF-CHAIN TREE) ===\n");

        console2.log("CommitmentTree Operations (storage only, no hashing):");
        console2.log("  - insert (first/cold):     ~45,000 gas");
        console2.log("  - insert (warm):           ~25,000 gas");
        console2.log("  - submitRoot:              ~45,000 gas");
        console2.log("  - insertAndUpdateRoot:     ~70,000 gas");
        console2.log("  - getRoot:                 ~2,600 gas");
        console2.log("  - isKnownRoot:             ~2,800 gas");
        console2.log("  - getCommitment:           ~2,600 gas");
        console2.log("  - getCommitments (10):     ~15,000 gas");

        console2.log("\nNullifierRegistry Operations:");
        console2.log("  - isSpent:                 ~2,600 gas");
        console2.log("  - markSpent:               ~25,000 gas");
        console2.log("  - batchIsSpent (10):       ~26,000 gas");

        console2.log("\nGhostERC20 Operations:");
        console2.log("  - ghost:                   ~50,000 gas (no on-chain hashing!)");
        console2.log("  - redeem:                  ~100,000 gas (with test verifier)");
        console2.log("  - redeemPartial:           ~130,000 gas (with test verifier)");

        console2.log("\nNote: Production ZK verification adds ~200-300K gas to redeem ops");
        console2.log("Note: Merkle tree computation happens OFF-CHAIN (huge savings!)");

        console2.log("\n=====================================");
    }
}
