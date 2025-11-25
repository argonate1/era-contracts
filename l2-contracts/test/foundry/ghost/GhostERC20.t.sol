// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GhostERC20Harness} from "./helpers/GhostERC20Harness.sol";
import {CommitmentTree} from "../../../contracts/ghost/CommitmentTree.sol";
import {NullifierRegistry} from "../../../contracts/ghost/NullifierRegistry.sol";
import {GhostVerifier} from "../../../contracts/ghost/GhostVerifier.sol";

contract GhostERC20Test is Test {
    GhostERC20Harness public ghostToken;
    CommitmentTree public tree;
    NullifierRegistry public nullifierRegistry;
    GhostVerifier public verifier;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public relayer = address(0x4);

    bytes32 public constant TEST_ASSET_ID = keccak256("TEST_ASSET");
    address public constant ORIGIN_TOKEN = address(0x1234);

    // Precomputed initial root for empty tree (Z20 - must match SDK)
    bytes32 constant INITIAL_ROOT = bytes32(0x0b4a6c626bd085f652fb17cad5b70c9db903266b5a3f456ea6373a3cf97f3453);

    event Ghosted(address indexed from, uint256 amount, bytes32 indexed commitment, uint256 leafIndex);
    event Redeemed(uint256 amount, address indexed recipient, bytes32 indexed nullifier);
    event PartialRedeemed(uint256 redeemAmount, address indexed recipient, bytes32 indexed oldNullifier, bytes32 indexed newCommitment, uint256 newLeafIndex);

    function setUp() public {
        // Deploy infrastructure
        tree = new CommitmentTree(INITIAL_ROOT);
        nullifierRegistry = new NullifierRegistry();
        verifier = new GhostVerifier(true); // Test mode - accepts all proofs

        // Set relayer as root submitter
        tree.setRootSubmitter(relayer);

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

    // ============ Helper Functions ============

    /// @notice Compute a test commitment using keccak256 (for testing only)
    /// @dev In production, commitments are computed off-chain using Poseidon
    function _computeTestCommitment(
        bytes32 secret,
        bytes32 nullifier,
        uint256 amount,
        address token
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(secret, nullifier, amount, token));
    }

    /// @notice Build a dummy merkle proof for test mode verifier
    function _buildDummyProof() internal pure returns (
        bytes32[] memory merkleProof,
        uint256[] memory pathIndices,
        bytes memory zkProof
    ) {
        merkleProof = new bytes32[](20);
        pathIndices = new uint256[](20);
        // Fill with zeros (dummy proof for test mode)
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = bytes32(0);
            pathIndices[i] = 0;
        }
        zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    // ============ Initialization Tests ============

    function test_Initialize_CorrectName() public view {
        assertEq(ghostToken.name(), "Ghost Test Token");
    }

    function test_Initialize_CorrectSymbol() public view {
        assertEq(ghostToken.symbol(), "gTEST");
    }

    function test_Initialize_CorrectDecimals() public view {
        assertEq(ghostToken.decimals(), 18);
    }

    function test_Initialize_CorrectOriginToken() public view {
        assertEq(ghostToken.originToken(), ORIGIN_TOKEN);
    }

    // ============ Ghost Tests ============

    function test_Ghost_Success() public {
        uint256 amount = 1000 ether;
        bytes32 secret = keccak256("secret");
        bytes32 nullifier = keccak256("nullifier");
        bytes32 commitment = _computeTestCommitment(secret, nullifier, amount, address(ghostToken));

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
        bytes32 commitment = _computeTestCommitment(secret, nullifier, amount, address(ghostToken));

        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        // Relayer submits root after commitment is inserted
        bytes32 newRoot = keccak256("test_root_1");
        vm.prank(relayer);
        tree.submitRoot(newRoot, 1);

        // Redeem to bob (different address - breaks the link!)
        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        uint256 bobBalanceBefore = ghostToken.balanceOf(bob);

        vm.expectEmit(true, true, true, true);
        emit Redeemed(amount, bob, nullifier);

        ghostToken.redeem(amount, bob, nullifier, newRoot, merkleProof, pathIndices, zkProof);

        assertEq(ghostToken.balanceOf(bob), bobBalanceBefore + amount, "Bob should receive tokens");
        assertEq(ghostToken.totalRedeemed(), amount, "Total redeemed should increase");
        assertTrue(nullifierRegistry.isSpent(nullifier), "Nullifier should be spent");
    }

    function test_Redeem_ZeroAmount_Reverts() public {
        bytes32 nullifier = keccak256("nullifier");
        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        vm.expectRevert(GhostERC20Harness.ZeroAmount.selector);
        ghostToken.redeem(0, bob, nullifier, INITIAL_ROOT, merkleProof, pathIndices, zkProof);
    }

    function test_Redeem_ZeroRecipient_Reverts() public {
        bytes32 nullifier = keccak256("nullifier");
        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        vm.expectRevert(GhostERC20Harness.ZeroAddress.selector);
        ghostToken.redeem(1000 ether, address(0), nullifier, INITIAL_ROOT, merkleProof, pathIndices, zkProof);
    }

    function test_Redeem_DoubleSpend_Reverts() public {
        // Ghost tokens
        uint256 amount = 1000 ether;
        bytes32 commitment = keccak256("commitment");
        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        // Relayer submits root
        bytes32 newRoot = keccak256("test_root_2");
        vm.prank(relayer);
        tree.submitRoot(newRoot, 1);

        bytes32 nullifier = keccak256("nullifier");
        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        // First redemption succeeds
        ghostToken.redeem(amount, bob, nullifier, newRoot, merkleProof, pathIndices, zkProof);

        // Second redemption with same nullifier should fail
        vm.expectRevert(GhostERC20Harness.NullifierAlreadySpent.selector);
        ghostToken.redeem(amount, charlie, nullifier, newRoot, merkleProof, pathIndices, zkProof);
    }

    function test_Redeem_UnknownRoot_Reverts() public {
        bytes32 unknownRoot = keccak256("unknown_root");
        bytes32 nullifier = keccak256("nullifier");
        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

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

        // Relayer submits root
        bytes32 newRoot = keccak256("test_root_3");
        vm.prank(relayer);
        tree.submitRoot(newRoot, 1);

        bytes32 oldNullifier = keccak256("old_nullifier");
        bytes32 newCommitment = keccak256("new_commitment"); // For remaining 400

        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        uint256 redeemAmount = 600 ether;

        vm.expectEmit(true, true, true, true);
        emit PartialRedeemed(redeemAmount, bob, oldNullifier, newCommitment, 1);

        uint256 newLeafIndex = ghostToken.redeemPartial(
            redeemAmount,
            originalAmount,
            bob,
            oldNullifier,
            newCommitment,
            newRoot,
            merkleProof,
            pathIndices,
            zkProof
        );

        assertEq(ghostToken.balanceOf(bob), redeemAmount, "Bob should receive partial amount");
        assertEq(newLeafIndex, 1, "New commitment should be at index 1");
        assertTrue(nullifierRegistry.isSpent(oldNullifier), "Old nullifier should be spent");
    }

    function test_RedeemPartial_ExceedsOriginal_Reverts() public {
        bytes32 oldNullifier = keccak256("nullifier");
        bytes32 newCommitment = keccak256("new_commitment");
        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        // Insert a commitment first to have a known root
        tree.insert(keccak256("dummy"));

        // Relayer submits root
        bytes32 newRoot = keccak256("test_root_4");
        vm.prank(relayer);
        tree.submitRoot(newRoot, 1);

        vm.expectRevert(GhostERC20Harness.InsufficientRedeemAmount.selector);
        ghostToken.redeemPartial(
            2000 ether, // More than original
            1000 ether,
            bob,
            oldNullifier,
            newCommitment,
            newRoot,
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

        // Relayer submits root
        bytes32 newRoot = keccak256("test_root_5");
        vm.prank(relayer);
        tree.submitRoot(newRoot, 1);

        // Charlie (not Alice!) redeems to Bob
        // This demonstrates the privacy model - anyone can submit the redeem tx
        bytes32 nullifier = keccak256("nullifier");
        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        vm.prank(charlie); // Charlie submits the tx
        ghostToken.redeem(amount, bob, nullifier, newRoot, merkleProof, pathIndices, zkProof);

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
