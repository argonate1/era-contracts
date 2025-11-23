// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GhostERC20Harness} from "./helpers/GhostERC20Harness.sol";
import {CommitmentTree} from "../../../contracts/ghost/CommitmentTree.sol";
import {NullifierRegistry} from "../../../contracts/ghost/NullifierRegistry.sol";
import {GhostVerifier} from "../../../contracts/ghost/GhostVerifier.sol";
import {GhostHash} from "../../../contracts/ghost/libraries/GhostHash.sol";

contract GhostERC20Test is Test {
    GhostERC20Harness public ghostToken;
    CommitmentTree public tree;
    NullifierRegistry public nullifierRegistry;
    GhostVerifier public verifier;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    bytes32 public constant TEST_ASSET_ID = keccak256("TEST_ASSET");
    address public constant ORIGIN_TOKEN = address(0x1234);

    event Ghosted(address indexed from, uint256 amount, bytes32 indexed commitment, uint256 leafIndex);
    event Redeemed(uint256 amount, address indexed recipient, bytes32 indexed nullifier);
    event PartialRedeemed(uint256 redeemAmount, address indexed recipient, bytes32 indexed oldNullifier, bytes32 indexed newCommitment, uint256 newLeafIndex);

    function setUp() public {
        // Deploy infrastructure
        tree = new CommitmentTree();
        nullifierRegistry = new NullifierRegistry();
        verifier = new GhostVerifier(true); // Test mode - accepts all proofs

        // Deploy ghost token (using test harness without _disableInitializers)
        ghostToken = new GhostERC20Harness();
        ghostToken.initialize(
            TEST_ASSET_ID,
            ORIGIN_TOKEN,
            "Test Token",
            "TEST",
            18,
            address(tree),
            address(nullifierRegistry),
            address(verifier)
        );

        // Authorize ghost token to insert commitments and mark nullifiers
        tree.authorizeInserter(address(ghostToken));
        nullifierRegistry.authorizeMarker(address(ghostToken));

        // Mint some tokens to alice for testing
        vm.prank(address(ghostToken.nativeTokenVault()));
        // Since owner deployed, owner is NTV
        ghostToken.bridgeMint(alice, 10000 ether);
    }

    // ============ Initialization Tests ============

    function test_Initialize_CorrectName() public {
        assertEq(ghostToken.name(), "Ghost Test Token");
    }

    function test_Initialize_CorrectSymbol() public {
        assertEq(ghostToken.symbol(), "gTEST");
    }

    function test_Initialize_CorrectDecimals() public {
        assertEq(ghostToken.decimals(), 18);
    }

    function test_Initialize_CorrectOriginToken() public {
        assertEq(ghostToken.originToken(), ORIGIN_TOKEN);
    }

    // ============ Ghost Tests ============

    function test_Ghost_Success() public {
        uint256 amount = 1000 ether;
        bytes32 secret = keccak256("secret");
        bytes32 nullifier = keccak256("nullifier");
        bytes32 commitment = GhostHash.computeCommitment(secret, nullifier, amount, address(ghostToken));

        uint256 aliceBalanceBefore = ghostToken.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Ghosted(alice, amount, commitment, 0);
        uint256 leafIndex = ghostToken.ghost(amount, commitment);

        assertEq(leafIndex, 0, "First ghost should be leaf index 0");
        assertEq(ghostToken.balanceOf(alice), aliceBalanceBefore - amount, "Balance should decrease");
        assertEq(ghostToken.totalGhosted(), amount, "Total ghosted should increase");
    }

    function test_Ghost_ZeroAmount_Reverts() public {
        bytes32 commitment = keccak256("commitment");

        vm.prank(alice);
        vm.expectRevert(GhostERC20Harness.ZeroAmount.selector);
        ghostToken.ghost(0, commitment);
    }

    function test_Ghost_InsufficientBalance_Reverts() public {
        bytes32 commitment = keccak256("commitment");

        vm.prank(alice);
        vm.expectRevert(); // ERC20 insufficient balance
        ghostToken.ghost(20000 ether, commitment);
    }

    function test_Ghost_MultipleCommitments() public {
        bytes32 commitment1 = keccak256("commitment1");
        bytes32 commitment2 = keccak256("commitment2");
        bytes32 commitment3 = keccak256("commitment3");

        vm.startPrank(alice);
        uint256 idx1 = ghostToken.ghost(100 ether, commitment1);
        uint256 idx2 = ghostToken.ghost(200 ether, commitment2);
        uint256 idx3 = ghostToken.ghost(300 ether, commitment3);
        vm.stopPrank();

        assertEq(idx1, 0);
        assertEq(idx2, 1);
        assertEq(idx3, 2);
        assertEq(ghostToken.totalGhosted(), 600 ether);
    }

    // ============ Redeem Tests ============

    function test_Redeem_Success() public {
        // First, ghost some tokens
        uint256 amount = 1000 ether;
        bytes32 secret = keccak256("secret");
        bytes32 nullifier = keccak256("nullifier");
        bytes32 commitment = GhostHash.computeCommitment(secret, nullifier, amount, address(ghostToken));

        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        bytes32 merkleRoot = tree.getRoot();

        // Redeem to bob (different address - breaks the link!)
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = tree.getZeroValue(i);
            pathIndices[i] = 0;
        }

        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2))); // Dummy proof for test mode

        uint256 bobBalanceBefore = ghostToken.balanceOf(bob);

        vm.expectEmit(true, true, true, true);
        emit Redeemed(amount, bob, nullifier);

        ghostToken.redeem(amount, bob, nullifier, merkleRoot, merkleProof, pathIndices, zkProof);

        assertEq(ghostToken.balanceOf(bob), bobBalanceBefore + amount, "Bob should receive tokens");
        assertEq(ghostToken.totalRedeemed(), amount, "Total redeemed should increase");
        assertTrue(nullifierRegistry.isSpent(nullifier), "Nullifier should be spent");
    }

    function test_Redeem_ZeroAmount_Reverts() public {
        bytes32 nullifier = keccak256("nullifier");
        bytes32 merkleRoot = tree.getRoot();
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        vm.expectRevert(GhostERC20Harness.ZeroAmount.selector);
        ghostToken.redeem(0, bob, nullifier, merkleRoot, merkleProof, pathIndices, zkProof);
    }

    function test_Redeem_ZeroRecipient_Reverts() public {
        bytes32 nullifier = keccak256("nullifier");
        bytes32 merkleRoot = tree.getRoot();
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        vm.expectRevert(GhostERC20Harness.ZeroAddress.selector);
        ghostToken.redeem(1000 ether, address(0), nullifier, merkleRoot, merkleProof, pathIndices, zkProof);
    }

    function test_Redeem_DoubleSpend_Reverts() public {
        // Ghost tokens
        uint256 amount = 1000 ether;
        bytes32 commitment = keccak256("commitment");
        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        bytes32 merkleRoot = tree.getRoot();
        bytes32 nullifier = keccak256("nullifier");
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = tree.getZeroValue(i);
            pathIndices[i] = 0;
        }
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        // First redemption succeeds
        ghostToken.redeem(amount, bob, nullifier, merkleRoot, merkleProof, pathIndices, zkProof);

        // Second redemption with same nullifier should fail
        vm.expectRevert(GhostERC20Harness.NullifierAlreadySpent.selector);
        ghostToken.redeem(amount, charlie, nullifier, merkleRoot, merkleProof, pathIndices, zkProof);
    }

    function test_Redeem_UnknownRoot_Reverts() public {
        bytes32 unknownRoot = keccak256("unknown_root");
        bytes32 nullifier = keccak256("nullifier");
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        vm.expectRevert(GhostERC20Harness.UnknownMerkleRoot.selector);
        ghostToken.redeem(1000 ether, bob, nullifier, unknownRoot, merkleProof, pathIndices, zkProof);
    }

    // ============ Partial Redeem Tests ============

    function test_RedeemPartial_Success() public {
        // Ghost 1000 tokens
        uint256 originalAmount = 1000 ether;
        bytes32 commitment = keccak256("commitment");
        vm.prank(alice);
        ghostToken.ghost(originalAmount, commitment);

        bytes32 merkleRoot = tree.getRoot();
        bytes32 oldNullifier = keccak256("old_nullifier");
        bytes32 newCommitment = keccak256("new_commitment"); // For remaining 400

        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = tree.getZeroValue(i);
            pathIndices[i] = 0;
        }
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        uint256 redeemAmount = 600 ether;

        vm.expectEmit(true, true, true, true);
        emit PartialRedeemed(redeemAmount, bob, oldNullifier, newCommitment, 1);

        uint256 newLeafIndex = ghostToken.redeemPartial(
            redeemAmount,
            originalAmount,
            bob,
            oldNullifier,
            newCommitment,
            merkleRoot,
            merkleProof,
            pathIndices,
            zkProof
        );

        assertEq(ghostToken.balanceOf(bob), redeemAmount, "Bob should receive partial amount");
        assertEq(newLeafIndex, 1, "New commitment should be at index 1");
        assertTrue(nullifierRegistry.isSpent(oldNullifier), "Old nullifier should be spent");
    }

    function test_RedeemPartial_ExceedsOriginal_Reverts() public {
        bytes32 merkleRoot = tree.getRoot();
        bytes32 oldNullifier = keccak256("nullifier");
        bytes32 newCommitment = keccak256("new_commitment");
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        // Insert a commitment first to have a known root
        tree.insert(keccak256("dummy"));
        merkleRoot = tree.getRoot();

        vm.expectRevert(GhostERC20Harness.InsufficientRedeemAmount.selector);
        ghostToken.redeemPartial(
            2000 ether, // More than original
            1000 ether,
            bob,
            oldNullifier,
            newCommitment,
            merkleRoot,
            merkleProof,
            pathIndices,
            zkProof
        );
    }

    // ============ Statistics Tests ============

    function test_GetGhostStats() public {
        vm.startPrank(alice);
        ghostToken.ghost(500 ether, keccak256("c1"));
        ghostToken.ghost(300 ether, keccak256("c2"));
        vm.stopPrank();

        (uint256 ghosted, uint256 redeemed, uint256 outstanding) = ghostToken.getGhostStats();

        assertEq(ghosted, 800 ether);
        assertEq(redeemed, 0);
        assertEq(outstanding, 800 ether);
    }

    // ============ Privacy Verification Tests ============

    function test_Privacy_DifferentRedeemer() public {
        // Alice ghosts tokens
        uint256 amount = 1000 ether;
        bytes32 commitment = keccak256("commitment");
        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        // Charlie (not Alice!) redeems to Bob
        // This demonstrates the privacy model - anyone can submit the redeem tx
        bytes32 merkleRoot = tree.getRoot();
        bytes32 nullifier = keccak256("nullifier");
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = tree.getZeroValue(i);
            pathIndices[i] = 0;
        }
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        vm.prank(charlie); // Charlie submits the tx
        ghostToken.redeem(amount, bob, nullifier, merkleRoot, merkleProof, pathIndices, zkProof);

        // Bob receives tokens, but tx was submitted by Charlie
        // Observers see: Charlie called redeem, Bob got tokens
        // They CANNOT link this to Alice's ghost transaction
        assertEq(ghostToken.balanceOf(bob), amount);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Ghost_AnyAmount(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 10000 ether);

        bytes32 commitment = keccak256(abi.encodePacked("commitment_", amount));

        uint256 balanceBefore = ghostToken.balanceOf(alice);
        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        assertEq(ghostToken.balanceOf(alice), balanceBefore - amount);
        assertEq(ghostToken.totalGhosted(), amount);
    }
}
