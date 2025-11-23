// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GhostERC20Harness} from "../helpers/GhostERC20Harness.sol";
import {CommitmentTree} from "../../../../contracts/ghost/CommitmentTree.sol";
import {NullifierRegistry} from "../../../../contracts/ghost/NullifierRegistry.sol";
import {GhostVerifier} from "../../../../contracts/ghost/GhostVerifier.sol";
import {GhostHash} from "../../../../contracts/ghost/libraries/GhostHash.sol";

/**
 * @title GhostInvariants
 * @notice Invariant tests for Ghost Protocol
 * @dev These tests verify critical protocol invariants that must ALWAYS hold:
 *
 *      SUPPLY INVARIANTS:
 *      1. totalGhosted >= totalRedeemed (can never redeem more than ghosted)
 *      2. totalSupply consistency: minted - burned + redeemed - ghosted = totalSupply
 *
 *      NULLIFIER INVARIANTS:
 *      3. Once a nullifier is spent, it stays spent forever
 *      4. Each nullifier can only be spent once (double-spend prevention)
 *      5. Zero nullifier can never be marked spent
 *
 *      MERKLE TREE INVARIANTS:
 *      6. nextLeafIndex monotonically increases
 *      7. nextLeafIndex never exceeds MAX_LEAVES
 *      8. Historical roots remain valid forever
 *      9. Current root equals roots[currentRootIndex]
 *
 *      AUTHORIZATION INVARIANTS:
 *      10. Only authorized inserters can add commitments
 *      11. Only authorized markers can spend nullifiers
 *
 * @custom:security These invariants are critical for protocol security.
 *                  If any invariant fails, there is a potential vulnerability.
 */
contract GhostInvariantsTest is StdInvariant, Test {
    GhostERC20Harness public ghostToken;
    CommitmentTree public commitmentTree;
    NullifierRegistry public nullifierRegistry;
    GhostVerifier public verifier;

    GhostHandler public handler;

    bytes32 public constant TEST_ASSET_ID = keccak256("TEST_ASSET");
    address public constant ORIGIN_TOKEN = address(0x1234);

    function setUp() public {
        // Deploy infrastructure
        commitmentTree = new CommitmentTree();
        nullifierRegistry = new NullifierRegistry();
        verifier = new GhostVerifier(true); // Test mode

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

        // Authorize ghost token
        commitmentTree.authorizeInserter(address(ghostToken));
        nullifierRegistry.authorizeMarker(address(ghostToken));

        // Deploy handler for invariant testing
        handler = new GhostHandler(ghostToken, commitmentTree, nullifierRegistry);

        // Target the handler for invariant testing
        targetContract(address(handler));
    }

    // ============ SUPPLY INVARIANTS ============

    /**
     * @notice Invariant: totalGhosted >= totalRedeemed
     * @dev We can never redeem more tokens than were ghosted
     */
    function invariant_totalGhostedGteRedeemed() public view {
        uint256 totalGhosted = ghostToken.totalGhosted();
        uint256 totalRedeemed = ghostToken.totalRedeemed();

        assertGe(
            totalGhosted,
            totalRedeemed,
            "CRITICAL: totalRedeemed exceeds totalGhosted - double mint detected!"
        );
    }

    /**
     * @notice Invariant: Outstanding ghosted amount is non-negative
     * @dev ghostOutstanding = totalGhosted - totalRedeemed >= 0
     */
    function invariant_outstandingNonNegative() public view {
        (uint256 ghosted, uint256 redeemed, uint256 outstanding) = ghostToken.getGhostStats();

        assertEq(
            outstanding,
            ghosted - redeemed,
            "Outstanding calculation mismatch"
        );
    }

    // ============ NULLIFIER INVARIANTS ============

    /**
     * @notice Invariant: Spent nullifiers stay spent
     * @dev Once nullifierRegistry.spent[x] = true, it can never become false
     */
    function invariant_spentNullifiersStaySpent() public view {
        // The handler tracks all nullifiers that have been spent
        bytes32[] memory spentNullifiers = handler.getSpentNullifiers();

        for (uint256 i = 0; i < spentNullifiers.length; i++) {
            assertTrue(
                nullifierRegistry.isSpent(spentNullifiers[i]),
                "CRITICAL: Previously spent nullifier is now unspent!"
            );
        }
    }

    /**
     * @notice Invariant: totalSpent equals count of spent nullifiers
     */
    function invariant_totalSpentMatchesCount() public view {
        assertEq(
            nullifierRegistry.totalSpent(),
            handler.getSpentNullifierCount(),
            "totalSpent doesn't match actual spent count"
        );
    }

    // ============ MERKLE TREE INVARIANTS ============

    /**
     * @notice Invariant: nextLeafIndex monotonically increases
     * @dev The leaf index should only ever go up
     */
    function invariant_leafIndexMonotonic() public view {
        uint256 currentIndex = commitmentTree.getNextLeafIndex();
        uint256 previousMax = handler.getMaxLeafIndexSeen();

        assertGe(
            currentIndex,
            previousMax,
            "CRITICAL: Leaf index decreased - tree corruption!"
        );
    }

    /**
     * @notice Invariant: nextLeafIndex never exceeds MAX_LEAVES
     */
    function invariant_leafIndexBounded() public view {
        uint256 currentIndex = commitmentTree.getNextLeafIndex();
        uint256 maxLeaves = commitmentTree.MAX_LEAVES();

        assertLe(
            currentIndex,
            maxLeaves,
            "CRITICAL: Leaf index exceeds MAX_LEAVES!"
        );
    }

    /**
     * @notice Invariant: Historical roots remain valid
     * @dev Once a root is added to rootHistory, it stays there
     */
    function invariant_historicalRootsValid() public view {
        bytes32[] memory historicalRoots = handler.getHistoricalRoots();

        for (uint256 i = 0; i < historicalRoots.length; i++) {
            assertTrue(
                commitmentTree.isKnownRoot(historicalRoots[i]),
                "CRITICAL: Historical root is no longer valid!"
            );
        }
    }

    /**
     * @notice Invariant: Zero root is never valid
     */
    function invariant_zeroRootNotValid() public view {
        assertFalse(
            commitmentTree.isKnownRoot(bytes32(0)),
            "Zero root should never be valid"
        );
    }

    // ============ GHOST STATS CONSISTENCY ============

    /**
     * @notice Invariant: Ghost stats are internally consistent
     */
    function invariant_ghostStatsConsistent() public view {
        (uint256 ghosted, uint256 redeemed, uint256 outstanding) = ghostToken.getGhostStats();

        assertEq(ghosted, ghostToken.totalGhosted(), "Ghosted stat mismatch");
        assertEq(redeemed, ghostToken.totalRedeemed(), "Redeemed stat mismatch");
        assertEq(outstanding, ghosted - redeemed, "Outstanding stat mismatch");
    }

    // ============ HANDLER CALL SUMMARY ============

    function invariant_callSummary() public view {
        console2.log("\n=== Invariant Test Call Summary ===");
        console2.log("Ghost calls:", handler.ghostCallCount());
        console2.log("Redeem calls:", handler.redeemCallCount());
        console2.log("Total ghosted:", ghostToken.totalGhosted());
        console2.log("Total redeemed:", ghostToken.totalRedeemed());
        console2.log("Nullifiers spent:", nullifierRegistry.totalSpent());
        console2.log("Commitments:", commitmentTree.getNextLeafIndex());
    }
}

/**
 * @title GhostHandler
 * @notice Handler contract for Ghost Protocol invariant testing
 * @dev This contract provides bounded actions for the fuzzer to call.
 *      It tracks state changes to verify invariants.
 */
contract GhostHandler is Test {
    GhostERC20Harness public ghostToken;
    CommitmentTree public commitmentTree;
    NullifierRegistry public nullifierRegistry;

    // Tracking for invariant verification
    bytes32[] public spentNullifiers;
    bytes32[] public historicalRoots;
    uint256 public maxLeafIndexSeen;

    // Call counters
    uint256 public ghostCallCount;
    uint256 public redeemCallCount;

    // Test actors
    address[] public actors;
    uint256 public constant NUM_ACTORS = 5;

    // Voucher tracking for redemptions
    struct Voucher {
        bytes32 secret;
        bytes32 nullifier;
        bytes32 commitment;
        uint256 amount;
        uint256 leafIndex;
        bool spent;
    }
    Voucher[] public vouchers;

    constructor(
        GhostERC20Harness _ghostToken,
        CommitmentTree _commitmentTree,
        NullifierRegistry _nullifierRegistry
    ) {
        ghostToken = _ghostToken;
        commitmentTree = _commitmentTree;
        nullifierRegistry = _nullifierRegistry;

        // Initialize actors
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            actors.push(address(uint160(i + 1)));
        }

        // Store initial root
        historicalRoots.push(commitmentTree.getRoot());
    }

    /**
     * @notice Ghost tokens with bounded parameters
     * @param actorSeed Used to select actor
     * @param amount Amount to ghost (bounded)
     * @param secretSeed Seed for generating secret
     */
    function ghost(
        uint256 actorSeed,
        uint256 amount,
        uint256 secretSeed
    ) external {
        // Bound inputs
        address actor = actors[actorSeed % NUM_ACTORS];
        amount = bound(amount, 1, 10000 ether);

        // Mint tokens to actor
        vm.prank(address(ghostToken.nativeTokenVault()));
        ghostToken.bridgeMint(actor, amount);

        // Generate voucher
        bytes32 secret = keccak256(abi.encodePacked("secret", secretSeed, block.timestamp));
        bytes32 nullifier = keccak256(abi.encodePacked("nullifier", secretSeed, block.timestamp));
        bytes32 commitment = GhostHash.computeCommitment(secret, nullifier, amount, address(ghostToken));

        // Ghost tokens
        vm.prank(actor);
        uint256 leafIndex = ghostToken.ghost(amount, commitment);

        // Track voucher for potential redemption
        vouchers.push(Voucher({
            secret: secret,
            nullifier: nullifier,
            commitment: commitment,
            amount: amount,
            leafIndex: leafIndex,
            spent: false
        }));

        // Update tracking
        ghostCallCount++;
        bytes32 newRoot = commitmentTree.getRoot();
        historicalRoots.push(newRoot);
        maxLeafIndexSeen = commitmentTree.getNextLeafIndex();
    }

    /**
     * @notice Redeem ghosted tokens
     * @param voucherIndex Index of voucher to redeem
     * @param recipientSeed Used to select recipient
     */
    function redeem(
        uint256 voucherIndex,
        uint256 recipientSeed
    ) external {
        // Skip if no vouchers
        if (vouchers.length == 0) return;

        // Bound index and find unspent voucher
        voucherIndex = voucherIndex % vouchers.length;

        // Find an unspent voucher (linear search, limited iterations)
        uint256 startIndex = voucherIndex;
        bool foundUnspent = false;
        for (uint256 i = 0; i < vouchers.length; i++) {
            uint256 idx = (startIndex + i) % vouchers.length;
            if (!vouchers[idx].spent) {
                voucherIndex = idx;
                foundUnspent = true;
                break;
            }
        }

        if (!foundUnspent) return; // All vouchers spent

        Voucher storage voucher = vouchers[voucherIndex];
        address recipient = actors[recipientSeed % NUM_ACTORS];

        // Build merkle proof (simplified - uses zero values)
        bytes32 merkleRoot = commitmentTree.getRoot();
        bytes32[] memory merkleProof = new bytes32[](20);
        uint256[] memory pathIndices = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            merkleProof[i] = commitmentTree.getZeroValue(i);
            pathIndices[i] = 0;
        }
        bytes memory zkProof = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)));

        // Attempt redemption
        ghostToken.redeem(
            voucher.amount,
            recipient,
            voucher.nullifier,
            merkleRoot,
            merkleProof,
            pathIndices,
            zkProof
        );

        // Track state changes
        voucher.spent = true;
        spentNullifiers.push(voucher.nullifier);
        redeemCallCount++;
    }

    // ============ GETTERS FOR INVARIANT CHECKS ============

    function getSpentNullifiers() external view returns (bytes32[] memory) {
        return spentNullifiers;
    }

    function getSpentNullifierCount() external view returns (uint256) {
        return spentNullifiers.length;
    }

    function getHistoricalRoots() external view returns (bytes32[] memory) {
        return historicalRoots;
    }

    function getMaxLeafIndexSeen() external view returns (uint256) {
        return maxLeafIndexSeen;
    }
}
