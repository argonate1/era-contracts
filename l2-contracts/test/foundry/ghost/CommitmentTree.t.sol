// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {CommitmentTree} from "../../../contracts/ghost/CommitmentTree.sol";
import {GhostHash} from "../../../contracts/ghost/libraries/GhostHash.sol";

contract CommitmentTreeTest is Test {
    CommitmentTree public tree;

    address public alice = address(0x1);
    address public bob = address(0x2);

    event CommitmentInserted(bytes32 indexed commitment, uint256 indexed leafIndex, bytes32 newRoot);

    function setUp() public {
        tree = new CommitmentTree();
    }

    // ============ Basic Insertion Tests ============

    function test_Insert_FirstCommitment() public {
        bytes32 commitment = keccak256("test_commitment_1");

        // Note: We use (true, true, false, false) because:
        // - First indexed param (commitment): must match
        // - Second indexed param (leafIndex): must match
        // - Non-indexed data (newRoot): will change after insertion, so don't check
        vm.expectEmit(true, true, false, false);
        emit CommitmentInserted(commitment, 0, bytes32(0)); // Root doesn't need to match

        uint256 leafIndex = tree.insert(commitment);

        assertEq(leafIndex, 0, "First leaf should be index 0");
        assertEq(tree.getNextLeafIndex(), 1, "Next leaf index should be 1");
        // Verify root actually changed (it's not the initial empty root)
        assertTrue(tree.getRoot() != bytes32(0), "Root should be non-zero after insertion");
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
    }

    function test_Insert_RootChangesWithEachInsertion() public {
        bytes32 root1 = tree.getRoot();

        tree.insert(keccak256("commitment_1"));
        bytes32 root2 = tree.getRoot();

        tree.insert(keccak256("commitment_2"));
        bytes32 root3 = tree.getRoot();

        assertTrue(root1 != root2, "Root should change after first insertion");
        assertTrue(root2 != root3, "Root should change after second insertion");
        assertTrue(root1 != root3, "All roots should be different");
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

    // ============ Root History Tests ============

    function test_IsKnownRoot_CurrentRoot() public {
        tree.insert(keccak256("commitment"));
        bytes32 currentRoot = tree.getRoot();

        assertTrue(tree.isKnownRoot(currentRoot), "Current root should be known");
    }

    function test_IsKnownRoot_HistoricalRoot() public {
        tree.insert(keccak256("commitment_1"));
        bytes32 root1 = tree.getRoot();

        tree.insert(keccak256("commitment_2"));
        bytes32 root2 = tree.getRoot();

        assertTrue(tree.isKnownRoot(root1), "Historical root should be known");
        assertTrue(tree.isKnownRoot(root2), "Current root should be known");
    }

    function test_IsKnownRoot_ZeroIsNotKnown() public {
        assertFalse(tree.isKnownRoot(bytes32(0)), "Zero should not be a known root");
    }

    function test_IsKnownRoot_RandomNotKnown() public {
        bytes32 randomRoot = keccak256("random_root");
        assertFalse(tree.isKnownRoot(randomRoot), "Random root should not be known");
    }

    // ============ Proof Verification Tests ============

    function test_VerifyProof_ValidProof() public {
        // Insert a commitment
        bytes32 commitment = keccak256("test_commitment");
        tree.insert(commitment);
        bytes32 root = tree.getRoot();

        // Build a valid proof (for leaf index 0)
        bytes32[] memory pathElements = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);

        // For the first leaf, all siblings are zero values
        for (uint256 i = 0; i < 20; i++) {
            pathElements[i] = tree.getZeroValue(i);
            pathIndices[i] = 0; // Left child at every level
        }

        bool isValid = tree.verifyProof(commitment, pathElements, pathIndices, root);
        assertTrue(isValid, "Valid proof should verify");
    }

    function test_VerifyProof_InvalidProofLength() public {
        bytes32 commitment = keccak256("test");
        bytes32 root = tree.getRoot();

        bytes32[] memory shortPath = new bytes32[](10);
        uint256[] memory shortIndices = new uint256[](10);

        vm.expectRevert(CommitmentTree.InvalidProofLength.selector);
        tree.verifyProof(commitment, shortPath, shortIndices, root);
    }

    function test_VerifyProof_WrongCommitment() public {
        bytes32 commitment = keccak256("real_commitment");
        tree.insert(commitment);
        bytes32 root = tree.getRoot();

        bytes32[] memory pathElements = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            pathElements[i] = tree.getZeroValue(i);
            pathIndices[i] = 0;
        }

        bytes32 fakeCommitment = keccak256("fake_commitment");
        bool isValid = tree.verifyProof(fakeCommitment, pathElements, pathIndices, root);
        assertFalse(isValid, "Proof with wrong commitment should fail");
    }

    // ============ Tree Capacity Tests ============

    function test_TreeDepth() public {
        assertEq(tree.TREE_DEPTH(), 20, "Tree depth should be 20");
    }

    function test_MaxLeaves() public {
        assertEq(tree.MAX_LEAVES(), 2**20, "Max leaves should be 2^20");
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
    }

    function testFuzz_Insert_UniqueRoots(bytes32 commitment1, bytes32 commitment2) public {
        vm.assume(commitment1 != commitment2);

        tree.insert(commitment1);
        bytes32 root1 = tree.getRoot();

        // Create new tree for comparison
        CommitmentTree tree2 = new CommitmentTree();
        tree2.insert(commitment2);
        bytes32 root2 = tree2.getRoot();

        assertTrue(root1 != root2, "Different commitments should produce different roots");
    }
}
