// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {CommitmentTree} from "../../../contracts/ghost/CommitmentTree.sol";

/// @title CommitmentTreeTest
/// @notice Tests for the off-chain Merkle tree CommitmentTree contract
/// @dev Note: This contract now stores commitments and roots, but tree is computed off-chain
contract CommitmentTreeTest is Test {
    CommitmentTree public tree;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public relayer = address(0x3);

    // Precomputed initial root for empty tree (Z20 - must match SDK)
    bytes32 constant INITIAL_ROOT = bytes32(0x0b4a6c626bd085f652fb17cad5b70c9db903266b5a3f456ea6373a3cf97f3453);

    event CommitmentInserted(bytes32 indexed commitment, uint256 indexed leafIndex, bytes32 newRoot);
    event RootUpdated(bytes32 indexed root, uint256 leafCount);

    function setUp() public {
        tree = new CommitmentTree(INITIAL_ROOT);
        tree.setRootSubmitter(relayer);
    }

    // ============ Basic Insertion Tests ============

    function test_Insert_FirstCommitment() public {
        bytes32 commitment = keccak256("test_commitment_1");

        // Expect event with newRoot = 0 (root computed off-chain)
        vm.expectEmit(true, true, false, true);
        emit CommitmentInserted(commitment, 0, bytes32(0));

        uint256 leafIndex = tree.insert(commitment);

        assertEq(leafIndex, 0, "First leaf should be index 0");
        assertEq(tree.getNextLeafIndex(), 1, "Next leaf index should be 1");
        assertEq(tree.getCommitmentCount(), 1, "Commitment count should be 1");
        assertEq(tree.getCommitment(0), commitment, "Commitment should be stored");
        // Root should still be initial (relayer hasn't updated yet)
        assertEq(tree.getRoot(), INITIAL_ROOT, "Root unchanged until relayer submits");
    }

    function test_Insert_MultipleCommitments() public {
        bytes32 commitment1 = keccak256("commitment_1");
        bytes32 commitment2 = keccak256("commitment_2");
        bytes32 commitment3 = keccak256("commitment_3");

        uint256 idx1 = tree.insert(commitment1);
        uint256 idx2 = tree.insert(commitment2);
        uint256 idx3 = tree.insert(commitment3);

        assertEq(idx1, 0);
        assertEq(idx2, 1);
        assertEq(idx3, 2);
        assertEq(tree.getNextLeafIndex(), 3);
        assertEq(tree.getCommitmentCount(), 3);
    }

    // ============ Root Submission Tests ============

    function test_SubmitRoot_ByRelayer() public {
        bytes32 commitment = keccak256("commitment_1");
        tree.insert(commitment);

        bytes32 newRoot = keccak256("computed_root_1");

        vm.prank(relayer);
        vm.expectEmit(true, false, false, true);
        emit RootUpdated(newRoot, 1);
        tree.submitRoot(newRoot, 1);

        assertEq(tree.getRoot(), newRoot, "Root should be updated");
        assertTrue(tree.isKnownRoot(newRoot), "New root should be known");
        assertTrue(tree.isKnownRoot(INITIAL_ROOT), "Initial root should still be known");
    }

    function test_SubmitRoot_InvalidLeafCount() public {
        tree.insert(keccak256("commitment"));

        bytes32 newRoot = keccak256("root");

        vm.prank(relayer);
        vm.expectRevert(CommitmentTree.InvalidLeafCount.selector);
        tree.submitRoot(newRoot, 0); // Wrong count (should be 1)
    }

    function test_SubmitRoot_DuplicateRoot() public {
        tree.insert(keccak256("commitment"));

        bytes32 newRoot = keccak256("root_1");

        vm.prank(relayer);
        tree.submitRoot(newRoot, 1);

        // Try to submit same root again
        tree.insert(keccak256("commitment_2"));
        vm.prank(relayer);
        vm.expectRevert(CommitmentTree.RootAlreadySubmitted.selector);
        tree.submitRoot(newRoot, 2); // Same root, different count - should fail
    }

    function test_SubmitRoot_OnlyRelayer() public {
        tree.insert(keccak256("commitment"));
        bytes32 newRoot = keccak256("root");

        vm.prank(alice);
        vm.expectRevert(CommitmentTree.Unauthorized.selector);
        tree.submitRoot(newRoot, 1);
    }

    // ============ InsertAndUpdateRoot Tests ============

    function test_InsertAndUpdateRoot() public {
        bytes32 commitment = keccak256("commitment_1");
        bytes32 newRoot = keccak256("root_after_insert");

        vm.prank(relayer);
        uint256 idx = tree.insertAndUpdateRoot(commitment, newRoot);

        assertEq(idx, 0, "Should return leaf index 0");
        assertEq(tree.getCommitment(0), commitment, "Commitment stored");
        assertEq(tree.getRoot(), newRoot, "Root updated atomically");
        assertTrue(tree.isKnownRoot(newRoot), "New root is known");
    }

    function test_InsertAndUpdateRoot_OnlyRelayer() public {
        vm.prank(alice);
        vm.expectRevert(CommitmentTree.Unauthorized.selector);
        tree.insertAndUpdateRoot(keccak256("c"), keccak256("r"));
    }

    // ============ Authorization Tests ============

    function test_Insert_OnlyAuthorized() public {
        // Owner is authorized by default
        tree.insert(keccak256("owner_commitment"));

        // Unauthorized user should fail
        vm.prank(alice);
        vm.expectRevert(CommitmentTree.Unauthorized.selector);
        tree.insert(keccak256("alice_commitment"));
    }

    function test_AuthorizeInserter() public {
        // Authorize alice
        tree.authorizeInserter(alice);

        // Alice should now be able to insert
        vm.prank(alice);
        uint256 idx = tree.insert(keccak256("alice_commitment"));
        assertEq(idx, 0);
    }

    function test_RevokeInserter() public {
        tree.authorizeInserter(alice);
        tree.revokeInserter(alice);

        vm.prank(alice);
        vm.expectRevert(CommitmentTree.Unauthorized.selector);
        tree.insert(keccak256("alice_commitment"));
    }

    function test_AuthorizeInserter_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(CommitmentTree.Unauthorized.selector);
        tree.authorizeInserter(bob);
    }

    function test_SetRootSubmitter_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(CommitmentTree.Unauthorized.selector);
        tree.setRootSubmitter(bob);
    }

    function test_TransferOwnership() public {
        tree.transferOwnership(alice);
        assertEq(tree.owner(), alice, "Ownership transferred");

        // Old owner can't do owner actions
        vm.expectRevert(CommitmentTree.Unauthorized.selector);
        tree.authorizeInserter(bob);

        // New owner can
        vm.prank(alice);
        tree.authorizeInserter(bob);
    }

    // ============ Root History Tests ============

    function test_IsKnownRoot_InitialRoot() public {
        assertTrue(tree.isKnownRoot(INITIAL_ROOT), "Initial root should be known");
    }

    function test_IsKnownRoot_ZeroIsNotKnown() public {
        assertFalse(tree.isKnownRoot(bytes32(0)), "Zero should not be a known root");
    }

    function test_IsKnownRoot_RandomNotKnown() public {
        bytes32 randomRoot = keccak256("random_root");
        assertFalse(tree.isKnownRoot(randomRoot), "Random root should not be known");
    }

    function test_CheckRoot_AliasForIsKnownRoot() public {
        assertTrue(tree.checkRoot(INITIAL_ROOT), "checkRoot should work like isKnownRoot");
        assertFalse(tree.checkRoot(bytes32(0)), "checkRoot returns false for zero");
    }

    function test_RootHistory_Persistence() public {
        // Insert commitments and roots
        tree.insert(keccak256("c1"));
        bytes32 root1 = keccak256("r1");
        vm.prank(relayer);
        tree.submitRoot(root1, 1);

        tree.insert(keccak256("c2"));
        bytes32 root2 = keccak256("r2");
        vm.prank(relayer);
        tree.submitRoot(root2, 2);

        // All roots should be known
        assertTrue(tree.isKnownRoot(INITIAL_ROOT), "Initial root still known");
        assertTrue(tree.isKnownRoot(root1), "Root 1 still known");
        assertTrue(tree.isKnownRoot(root2), "Root 2 still known");
    }

    // ============ Proof Verification Tests ============

    function test_VerifyProof_Reverts() public {
        // verifyProof should always revert - proofs are verified in ZK circuits
        bytes32[] memory pathElements = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);

        vm.expectRevert(CommitmentTree.ProofVerificationNotSupported.selector);
        tree.verifyProof(keccak256("leaf"), pathElements, pathIndices, INITIAL_ROOT);
    }

    // ============ GetCommitments Range Query Test ============

    function test_GetCommitments_Range() public {
        // Insert 5 commitments
        for (uint i = 0; i < 5; i++) {
            tree.insert(keccak256(abi.encodePacked("commitment_", i)));
        }

        // Get commitments 1-3
        bytes32[] memory result = tree.getCommitments(1, 2);
        assertEq(result.length, 2, "Should return 2 commitments");
        assertEq(result[0], keccak256(abi.encodePacked("commitment_", uint256(1))));
        assertEq(result[1], keccak256(abi.encodePacked("commitment_", uint256(2))));
    }

    function test_GetCommitments_BeyondEnd() public {
        tree.insert(keccak256("c1"));
        tree.insert(keccak256("c2"));

        // Request more than available
        bytes32[] memory result = tree.getCommitments(1, 100);
        assertEq(result.length, 1, "Should cap at available commitments");
    }

    // ============ Tree Capacity Tests ============

    function test_TreeDepth() public {
        assertEq(tree.TREE_DEPTH(), 20, "Tree depth should be 20");
    }

    function test_MaxLeaves() public {
        assertEq(tree.MAX_LEAVES(), 2**20, "Max leaves should be 2^20");
    }

    // ============ Contract Type Tests ============

    function test_IsNotTestContract() public {
        assertFalse(tree.isTestContract(), "Should not be test contract");
    }

    function test_HashFunction() public {
        assertEq(tree.hashFunction(), "poseidon-offchain", "Hash function indicator");
    }

    // ============ Fuzz Tests ============

    function testFuzz_Insert_IncrementalIndex(uint8 count) public {
        vm.assume(count > 0 && count < 100); // Limit for gas

        for (uint8 i = 0; i < count; i++) {
            bytes32 commitment = keccak256(abi.encodePacked("commitment_", i));
            uint256 idx = tree.insert(commitment);
            assertEq(idx, i, "Index should match insertion order");
        }

        assertEq(tree.getNextLeafIndex(), count);
        assertEq(tree.getCommitmentCount(), count);
    }

    function testFuzz_SubmitRoot_AnyValidRoot(bytes32 root1, bytes32 root2) public {
        vm.assume(root1 != bytes32(0) && root2 != bytes32(0));
        vm.assume(root1 != root2);
        vm.assume(root1 != INITIAL_ROOT && root2 != INITIAL_ROOT);

        tree.insert(keccak256("c1"));
        vm.prank(relayer);
        tree.submitRoot(root1, 1);
        assertTrue(tree.isKnownRoot(root1));

        tree.insert(keccak256("c2"));
        vm.prank(relayer);
        tree.submitRoot(root2, 2);
        assertTrue(tree.isKnownRoot(root2));
    }
}
