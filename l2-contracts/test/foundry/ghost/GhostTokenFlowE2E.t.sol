// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GhostERC20Harness} from "./helpers/GhostERC20Harness.sol";
import {CommitmentTree} from "../../../contracts/ghost/CommitmentTree.sol";
import {NullifierRegistry} from "../../../contracts/ghost/NullifierRegistry.sol";
import {GhostVerifier} from "../../../contracts/ghost/GhostVerifier.sol";

/**
 * @title GhostTokenFlowE2E
 * @notice End-to-end tests for Ghost Protocol with real token transfer verification
 * @dev Tests complete ghost→redeem cycles with balance checks at each step
 *
 * Test categories:
 * 1. Full ghost→redeem cycle with balance verification
 * 2. Partial redeem with change (split voucher)
 * 3. Multi-user anonymity set demonstration
 * 4. Security edge cases (double-spend, stale roots, etc.)
 *
 * Note: With off-chain tree architecture, commitments are stored on-chain
 * and roots are submitted by an authorized relayer. Tests simulate this flow.
 */
contract GhostTokenFlowE2E is Test {
    GhostERC20Harness public ghostToken;
    CommitmentTree public tree;
    NullifierRegistry public nullifierRegistry;
    GhostVerifier public verifier;

    // Test actors
    address public deployer = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public relayer = makeAddr("relayer");
    address public attacker = makeAddr("attacker");

    // Test constants
    bytes32 public constant TEST_ASSET_ID = keccak256("GHOST_TEST_ASSET");
    address public constant ORIGIN_TOKEN = address(0xBEEF);
    uint256 public constant INITIAL_MINT = 10000 ether;

    // Precomputed initial root for empty tree (Z20 - must match SDK)
    bytes32 constant INITIAL_ROOT = bytes32(0x0b4a6c626bd085f652fb17cad5b70c9db903266b5a3f456ea6373a3cf97f3453);

    // Root counter for unique test roots
    uint256 private rootCounter;

    // Events
    event Ghosted(address indexed from, uint256 amount, bytes32 indexed commitment, uint256 leafIndex);
    event Redeemed(uint256 amount, address indexed recipient, bytes32 indexed nullifier);
    event PartialRedeemed(uint256 redeemAmount, address indexed recipient, bytes32 indexed oldNullifier, bytes32 indexed newCommitment, uint256 newLeafIndex);

    function setUp() public {
        // Deploy infrastructure with initial root
        tree = new CommitmentTree(INITIAL_ROOT);
        nullifierRegistry = new NullifierRegistry();
        verifier = new GhostVerifier(true); // Test mode - accepts all proofs

        // Set relayer as root submitter
        tree.setRootSubmitter(relayer);

        // Deploy ghost token
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

        // Authorize ghost token
        tree.authorizeInserter(address(ghostToken));
        nullifierRegistry.authorizeMarker(address(ghostToken));

        // Mint tokens to test users via bridge simulation
        address ntv = address(ghostToken.nativeTokenVault());
        vm.startPrank(ntv);
        ghostToken.bridgeMint(alice, INITIAL_MINT);
        ghostToken.bridgeMint(bob, INITIAL_MINT);
        ghostToken.bridgeMint(charlie, INITIAL_MINT);
        vm.stopPrank();
    }

    // =========================================================================
    // HELPER FUNCTIONS
    // =========================================================================

    /**
     * @notice Build dummy merkle proof (for test verifier)
     */
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

    /**
     * @notice Create a voucher (secret + nullifier + commitment)
     * @dev Uses keccak256 for testing; production uses Poseidon off-chain
     */
    function _createVoucher(string memory seed, uint256 amount) internal view returns (
        bytes32 secret,
        bytes32 nullifier,
        bytes32 commitment
    ) {
        secret = keccak256(abi.encodePacked(seed, "_secret"));
        nullifier = keccak256(abi.encodePacked(seed, "_nullifier"));
        commitment = keccak256(abi.encodePacked(secret, nullifier, amount, address(ghostToken)));
    }

    /**
     * @notice Generate a unique test root
     */
    function _generateUniqueRoot() internal returns (bytes32) {
        rootCounter++;
        return keccak256(abi.encodePacked("test_root_", rootCounter));
    }

    /**
     * @notice Submit a root for the current commitment count
     */
    function _submitCurrentRoot() internal returns (bytes32 newRoot) {
        newRoot = _generateUniqueRoot();
        uint256 leafCount = tree.getCommitmentCount();
        vm.prank(relayer);
        tree.submitRoot(newRoot, leafCount);
    }

    // =========================================================================
    // FULL GHOST → REDEEM CYCLE TESTS
    // =========================================================================

    /**
     * @notice Test complete ghost→redeem cycle with full balance verification
     * @dev Alice ghosts tokens, Bob redeems them via relayer
     */
    function test_FullGhostRedeemCycle_BalanceVerification() public {
        uint256 amount = 1000 ether;

        // Record initial balances
        uint256 aliceInitial = ghostToken.balanceOf(alice);
        uint256 bobInitial = ghostToken.balanceOf(bob);
        uint256 supplyInitial = ghostToken.totalSupply();

        // Create voucher
        (bytes32 secret, bytes32 nullifier, bytes32 commitment) = _createVoucher("test1", amount);

        // === GHOST PHASE ===
        console2.log("=== GHOST PHASE ===");
        console2.log("Alice balance before ghost:", aliceInitial / 1e18, "tokens");

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Ghosted(alice, amount, commitment, 0);
        uint256 leafIndex = ghostToken.ghost(amount, commitment);

        // Verify ghost results
        assertEq(leafIndex, 0, "First leaf should be index 0");
        assertEq(ghostToken.balanceOf(alice), aliceInitial - amount, "Alice balance decreased");
        assertEq(ghostToken.totalSupply(), supplyInitial - amount, "Supply decreased during ghost");
        assertEq(ghostToken.totalGhosted(), amount, "totalGhosted updated");

        console2.log("Alice balance after ghost:", ghostToken.balanceOf(alice) / 1e18, "tokens");
        console2.log("Supply after ghost:", ghostToken.totalSupply() / 1e18, "tokens");

        // === RELAYER SUBMITS ROOT ===
        bytes32 merkleRoot = _submitCurrentRoot();

        // === REDEEM PHASE ===
        console2.log("\n=== REDEEM PHASE ===");
        console2.log("Bob balance before redeem:", bobInitial / 1e18, "tokens");

        (bytes32[] memory merkleProof, uint256[] memory pathIndices, bytes memory zkProof) = _buildDummyProof();

        // Relayer submits redeem on behalf of Bob (privacy pattern)
        vm.prank(relayer);
        vm.expectEmit(true, true, true, true);
        emit Redeemed(amount, bob, nullifier);
        ghostToken.redeem(amount, bob, nullifier, merkleRoot, merkleProof, pathIndices, zkProof);

        // Verify redeem results
        assertEq(ghostToken.balanceOf(bob), bobInitial + amount, "Bob received tokens");
        assertEq(ghostToken.totalSupply(), supplyInitial, "Supply restored after redeem");
        assertEq(ghostToken.totalRedeemed(), amount, "totalRedeemed updated");
        assertTrue(nullifierRegistry.isSpent(nullifier), "Nullifier marked spent");

        console2.log("Bob balance after redeem:", ghostToken.balanceOf(bob) / 1e18, "tokens");
        console2.log("Supply after redeem:", ghostToken.totalSupply() / 1e18, "tokens");

        // === INVARIANT CHECKS ===
        (uint256 ghosted, uint256 redeemed, uint256 outstanding) = ghostToken.getGhostStats();
        assertEq(ghosted, amount, "Total ghosted correct");
        assertEq(redeemed, amount, "Total redeemed correct");
        assertEq(outstanding, 0, "No outstanding ghost balance");

        console2.log("\n=== FINAL STATE ===");
        console2.log("Total ghosted:", ghosted / 1e18, "tokens");
        console2.log("Total redeemed:", redeemed / 1e18, "tokens");
        console2.log("Outstanding:", outstanding / 1e18, "tokens");
    }

    /**
     * @notice Test ghost/redeem preserves total accounting
     */
    function test_GhostRedeem_TotalAccountingInvariant() public {
        uint256 amount1 = 500 ether;
        uint256 amount2 = 300 ether;

        // Ghost twice
        (,bytes32 nullifier1, bytes32 commitment1) = _createVoucher("v1", amount1);
        (,bytes32 nullifier2, bytes32 commitment2) = _createVoucher("v2", amount2);

        vm.startPrank(alice);
        ghostToken.ghost(amount1, commitment1);
        ghostToken.ghost(amount2, commitment2);
        vm.stopPrank();

        // Verify intermediate state
        (uint256 ghosted1,, uint256 outstanding1) = ghostToken.getGhostStats();
        assertEq(ghosted1, amount1 + amount2, "Both amounts ghosted");
        assertEq(outstanding1, amount1 + amount2, "Both amounts outstanding");

        // Relayer submits root
        bytes32 root = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        // Redeem first voucher
        ghostToken.redeem(amount1, bob, nullifier1, root, proof, indices, zk);

        // Verify after first redeem
        (uint256 ghosted2, uint256 redeemed2, uint256 outstanding2) = ghostToken.getGhostStats();
        assertEq(ghosted2, amount1 + amount2, "Total ghosted unchanged");
        assertEq(redeemed2, amount1, "First amount redeemed");
        assertEq(outstanding2, amount2, "Second amount still outstanding");

        // Redeem second voucher
        ghostToken.redeem(amount2, charlie, nullifier2, root, proof, indices, zk);

        // Verify final state
        (uint256 ghosted3, uint256 redeemed3, uint256 outstanding3) = ghostToken.getGhostStats();
        assertEq(ghosted3, amount1 + amount2, "Total ghosted unchanged");
        assertEq(redeemed3, amount1 + amount2, "Both redeemed");
        assertEq(outstanding3, 0, "Nothing outstanding");
    }

    // =========================================================================
    // PARTIAL REDEEM TESTS
    // =========================================================================

    /**
     * @notice Test partial redemption with change voucher
     * @dev Alice ghosts 1000, Bob gets 300, new voucher for 700 created
     */
    function test_PartialRedeem_WithChangeVoucher() public {
        uint256 originalAmount = 1000 ether;
        uint256 redeemAmount = 300 ether;
        uint256 remainingAmount = 700 ether;

        // Initial balances
        uint256 aliceInitial = ghostToken.balanceOf(alice);
        uint256 bobInitial = ghostToken.balanceOf(bob);

        // Create original voucher
        (bytes32 oldSecret, bytes32 oldNullifier, bytes32 oldCommitment) = _createVoucher("original", originalAmount);

        // Create new voucher for change
        (bytes32 newSecret, bytes32 newNullifier, bytes32 newCommitment) = _createVoucher("change", remainingAmount);

        // === GHOST PHASE ===
        vm.prank(alice);
        uint256 oldLeafIndex = ghostToken.ghost(originalAmount, oldCommitment);
        assertEq(oldLeafIndex, 0);

        // Relayer submits root
        bytes32 merkleRoot = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        // === PARTIAL REDEEM PHASE ===
        vm.expectEmit(true, true, true, true);
        emit PartialRedeemed(redeemAmount, bob, oldNullifier, newCommitment, 1);

        uint256 newLeafIndex = ghostToken.redeemPartial(
            redeemAmount,
            originalAmount,
            bob,
            oldNullifier,
            newCommitment,
            merkleRoot,
            proof,
            indices,
            zk
        );

        // Verify partial redeem results
        assertEq(newLeafIndex, 1, "New commitment at index 1");
        assertEq(ghostToken.balanceOf(alice), aliceInitial - originalAmount, "Alice lost original amount");
        assertEq(ghostToken.balanceOf(bob), bobInitial + redeemAmount, "Bob received redeem amount");
        assertTrue(nullifierRegistry.isSpent(oldNullifier), "Old nullifier spent");

        // === REDEEM REMAINING ===
        merkleRoot = _submitCurrentRoot(); // Get updated root with new commitment

        vm.expectEmit(true, true, true, true);
        emit Redeemed(remainingAmount, charlie, newNullifier);

        ghostToken.redeem(remainingAmount, charlie, newNullifier, merkleRoot, proof, indices, zk);

        // Verify final balances
        assertEq(ghostToken.balanceOf(charlie), INITIAL_MINT + remainingAmount, "Charlie received remainder");
        assertTrue(nullifierRegistry.isSpent(newNullifier), "New nullifier spent");

        // Verify total accounting
        (uint256 ghosted, uint256 redeemed,) = ghostToken.getGhostStats();
        assertEq(ghosted, originalAmount, "Only original ghosted");
        assertEq(redeemed, originalAmount, "Full amount redeemed across two txs");

        console2.log("=== PARTIAL REDEEM COMPLETE ===");
        console2.log("Original ghosted:", originalAmount / 1e18);
        console2.log("Bob received:", redeemAmount / 1e18);
        console2.log("Charlie received:", remainingAmount / 1e18);
    }

    /**
     * @notice Test multiple partial redeems splitting a voucher
     */
    function test_PartialRedeem_MultipleSplits() public {
        uint256 originalAmount = 1000 ether;

        // Create original voucher
        (,bytes32 nullifier1, bytes32 commitment1) = _createVoucher("split-original", originalAmount);

        vm.prank(alice);
        ghostToken.ghost(originalAmount, commitment1);

        bytes32 merkleRoot = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        // Split 1: 300 to Bob, 700 remaining
        (, bytes32 nullifier2, bytes32 commitment2) = _createVoucher("split-2", 700 ether);
        ghostToken.redeemPartial(300 ether, 1000 ether, bob, nullifier1, commitment2, merkleRoot, proof, indices, zk);
        assertEq(ghostToken.balanceOf(bob), INITIAL_MINT + 300 ether);

        // Split 2: 400 to Charlie, 300 remaining
        merkleRoot = _submitCurrentRoot();
        (, bytes32 nullifier3, bytes32 commitment3) = _createVoucher("split-3", 300 ether);
        ghostToken.redeemPartial(400 ether, 700 ether, charlie, nullifier2, commitment3, merkleRoot, proof, indices, zk);
        assertEq(ghostToken.balanceOf(charlie), INITIAL_MINT + 400 ether);

        // Final: 300 to Alice (self-redeem)
        merkleRoot = _submitCurrentRoot();
        ghostToken.redeem(300 ether, alice, nullifier3, merkleRoot, proof, indices, zk);

        // Verify total
        (uint256 ghosted, uint256 redeemed,) = ghostToken.getGhostStats();
        assertEq(ghosted, originalAmount);
        assertEq(redeemed, originalAmount);
    }

    // =========================================================================
    // MULTI-USER ANONYMITY SET TESTS
    // =========================================================================

    /**
     * @notice Test anonymity set with multiple users
     * @dev Multiple users ghost, then one redeems - observers can't link
     */
    function test_AnonymitySet_MultipleUsers() public {
        uint256 amount = 100 ether;

        // Create vouchers for 3 users
        (,bytes32 nullifierA, bytes32 commitmentA) = _createVoucher("alice", amount);
        (,bytes32 nullifierB, bytes32 commitmentB) = _createVoucher("bob", amount);
        (,bytes32 nullifierC, bytes32 commitmentC) = _createVoucher("charlie", amount);

        // All users ghost (builds anonymity set)
        vm.prank(alice);
        ghostToken.ghost(amount, commitmentA);

        vm.prank(bob);
        ghostToken.ghost(amount, commitmentB);

        vm.prank(charlie);
        ghostToken.ghost(amount, commitmentC);

        // Verify anonymity set size
        assertEq(ghostToken.totalGhosted(), amount * 3, "3 users in anonymity set");

        // Relayer submits root
        bytes32 merkleRoot = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        // Bob redeems via relayer to new address
        address bobNewWallet = makeAddr("bob-new-wallet");

        vm.prank(relayer); // Relayer submits tx (not Bob!)
        ghostToken.redeem(amount, bobNewWallet, nullifierB, merkleRoot, proof, indices, zk);

        // Verify Bob's new wallet received tokens
        assertEq(ghostToken.balanceOf(bobNewWallet), amount);

        // Privacy assertion: Observer sees:
        // - Alice, Bob, Charlie all ghosted 100 tokens (PUBLIC)
        // - Relayer called redeem, bobNewWallet received 100 tokens (PUBLIC)
        // - Cannot link: Which ghost corresponds to this redeem? (PRIVATE)

        console2.log("=== ANONYMITY SET TEST ===");
        console2.log("Anonymity set size: 3");
        console2.log("Ghosts: Alice, Bob, Charlie (all PUBLIC)");
        console2.log("Redeem submitted by: relayer (PUBLIC)");
        console2.log("Tokens received by: bobNewWallet (PUBLIC)");
        console2.log("Link between ghost and redeem: PRIVATE");
    }

    /**
     * @notice Test that redemption can be submitted by anyone (relayer pattern)
     */
    function test_RelayerPattern_AnyoneCanSubmit() public {
        uint256 amount = 500 ether;

        // Alice creates voucher
        (,bytes32 nullifier, bytes32 commitment) = _createVoucher("relayer-test", amount);

        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        bytes32 root = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        // Random attacker tries to "front-run" by submitting the tx
        // But tokens still go to the intended recipient (bob)
        vm.prank(attacker);
        ghostToken.redeem(amount, bob, nullifier, root, proof, indices, zk);

        // Attacker gains nothing, Bob receives tokens
        assertEq(ghostToken.balanceOf(attacker), 0, "Attacker got nothing");
        assertEq(ghostToken.balanceOf(bob), INITIAL_MINT + amount, "Bob received tokens");
    }

    // =========================================================================
    // SECURITY EDGE CASE TESTS
    // =========================================================================

    /**
     * @notice Test double-spend prevention
     */
    function test_Security_DoubleSpendPrevented() public {
        uint256 amount = 1000 ether;

        (,bytes32 nullifier, bytes32 commitment) = _createVoucher("double-spend", amount);

        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        bytes32 root = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        // First redemption succeeds
        ghostToken.redeem(amount, bob, nullifier, root, proof, indices, zk);
        assertTrue(nullifierRegistry.isSpent(nullifier));

        // Second redemption with same nullifier fails
        vm.expectRevert(GhostERC20Harness.NullifierAlreadySpent.selector);
        ghostToken.redeem(amount, charlie, nullifier, root, proof, indices, zk);
    }

    /**
     * @notice Test unknown root rejection
     * @dev CommitmentTree uses rootHistory mapping - all valid roots remain valid forever
     *      This test verifies that fabricated/unknown roots are rejected
     */
    function test_Security_UnknownRootRejected() public {
        // Ghost first token
        (,bytes32 nullifier1, bytes32 commitment1) = _createVoucher("unknown-root-test", 100 ether);
        vm.prank(alice);
        ghostToken.ghost(100 ether, commitment1);

        // Create a fabricated root that was never in the tree
        bytes32 fabricatedRoot = keccak256("this-root-never-existed");

        // Fabricated root should not be known
        assertFalse(tree.isKnownRoot(fabricatedRoot), "Fabricated root should not be known");

        // But real root should still be valid
        bytes32 realRoot = _submitCurrentRoot();
        assertTrue(tree.isKnownRoot(realRoot), "Real root should be known");

        // Try to redeem with fabricated root - should fail
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        vm.expectRevert(GhostERC20Harness.UnknownMerkleRoot.selector);
        ghostToken.redeem(100 ether, bob, nullifier1, fabricatedRoot, proof, indices, zk);
    }

    /**
     * @notice Test that old roots remain valid (by design)
     * @dev CommitmentTree keeps all roots valid forever for better UX
     */
    function test_Security_OldRootsRemainValid() public {
        // Ghost first token
        (,bytes32 nullifier1, bytes32 commitment1) = _createVoucher("old-root-test", 100 ether);
        vm.prank(alice);
        ghostToken.ghost(100 ether, commitment1);

        bytes32 oldRoot = _submitCurrentRoot();

        // Add many more commitments
        for (uint256 i = 0; i < 50; i++) {
            bytes32 c = keccak256(abi.encodePacked("filler", i));
            vm.prank(alice);
            ghostToken.ghost(1 ether, c);
        }

        // Submit new root
        _submitCurrentRoot();

        // Old root should STILL be valid (this is by design)
        assertTrue(tree.isKnownRoot(oldRoot), "Old root should remain valid");

        // Can still redeem using old root
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();
        ghostToken.redeem(100 ether, bob, nullifier1, oldRoot, proof, indices, zk);

        assertEq(ghostToken.balanceOf(bob), INITIAL_MINT + 100 ether, "Bob should receive tokens");
    }

    /**
     * @notice Test zero amount rejection
     */
    function test_Security_ZeroAmountRejected() public {
        bytes32 commitment = keccak256("zero-commitment");

        vm.prank(alice);
        vm.expectRevert(GhostERC20Harness.ZeroAmount.selector);
        ghostToken.ghost(0, commitment);
    }

    /**
     * @notice Test zero recipient rejection
     */
    function test_Security_ZeroRecipientRejected() public {
        uint256 amount = 100 ether;
        (,bytes32 nullifier, bytes32 commitment) = _createVoucher("zero-recipient", amount);

        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        bytes32 root = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        vm.expectRevert(GhostERC20Harness.ZeroAddress.selector);
        ghostToken.redeem(amount, address(0), nullifier, root, proof, indices, zk);
    }

    /**
     * @notice Test partial redeem amount exceeds original
     */
    function test_Security_PartialRedeemExceedsOriginal() public {
        uint256 originalAmount = 100 ether;
        (,bytes32 nullifier, bytes32 commitment) = _createVoucher("exceed", originalAmount);

        vm.prank(alice);
        ghostToken.ghost(originalAmount, commitment);

        bytes32 root = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        bytes32 newCommitment = keccak256("new");

        vm.expectRevert(GhostERC20Harness.InsufficientRedeemAmount.selector);
        ghostToken.redeemPartial(
            200 ether, // More than original!
            originalAmount,
            bob,
            nullifier,
            newCommitment,
            root,
            proof,
            indices,
            zk
        );
    }

    /**
     * @notice Test that different secrets produce different nullifiers
     */
    function test_Security_NullifierUniqueness() public pure {
        uint256 amount = 100 ether;

        // Two different vouchers with same amount
        bytes32 secretA = keccak256(abi.encodePacked("user-a", "_secret"));
        bytes32 nullifierA = keccak256(abi.encodePacked("user-a", "_nullifier"));

        bytes32 secretB = keccak256(abi.encodePacked("user-b", "_secret"));
        bytes32 nullifierB = keccak256(abi.encodePacked("user-b", "_nullifier"));

        // Nullifiers must be different
        assertNotEq(nullifierA, nullifierB, "Nullifiers should be unique");
    }

    // =========================================================================
    // GAS BENCHMARKS
    // =========================================================================

    /**
     * @notice Measure gas for ghost operation
     */
    function test_Gas_GhostOperation() public {
        uint256 amount = 1000 ether;
        bytes32 commitment = keccak256("gas-test");

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        ghostToken.ghost(amount, commitment);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for ghost():", gasUsed);
        // Note: With off-chain tree, ghost is much cheaper (no Poseidon hashing)
        // Gas includes ERC20 burn + commitment insertion (cold storage)
        assertLt(gasUsed, 110000, "Ghost should use < 110K gas with off-chain tree");
    }

    /**
     * @notice Measure gas for redeem operation
     */
    function test_Gas_RedeemOperation() public {
        uint256 amount = 1000 ether;
        (,bytes32 nullifier, bytes32 commitment) = _createVoucher("gas-redeem", amount);

        vm.prank(alice);
        ghostToken.ghost(amount, commitment);

        bytes32 root = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        uint256 gasBefore = gasleft();
        ghostToken.redeem(amount, bob, nullifier, root, proof, indices, zk);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for redeem():", gasUsed);
        assertLt(gasUsed, 200000, "Redeem should use < 200K gas with test verifier");
    }

    /**
     * @notice Measure gas for partial redeem operation
     */
    function test_Gas_PartialRedeemOperation() public {
        uint256 originalAmount = 1000 ether;
        uint256 redeemAmount = 300 ether;
        (,bytes32 nullifier, bytes32 commitment) = _createVoucher("gas-partial", originalAmount);
        bytes32 newCommitment = keccak256("gas-change");

        vm.prank(alice);
        ghostToken.ghost(originalAmount, commitment);

        bytes32 root = _submitCurrentRoot();
        (bytes32[] memory proof, uint256[] memory indices, bytes memory zk) = _buildDummyProof();

        uint256 gasBefore = gasleft();
        ghostToken.redeemPartial(
            redeemAmount,
            originalAmount,
            bob,
            nullifier,
            newCommitment,
            root,
            proof,
            indices,
            zk
        );
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for redeemPartial():", gasUsed);
        // Note: With off-chain tree, partial redeem is much cheaper
        assertLt(gasUsed, 250000, "Partial redeem should use < 250K gas with test verifier");
    }
}
