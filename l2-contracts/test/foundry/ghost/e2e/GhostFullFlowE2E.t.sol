// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GhostE2EBase} from "./GhostE2EBase.sol";
import {GhostERC20Harness} from "../helpers/GhostERC20Harness.sol";
import {console2} from "forge-std/Test.sol";

/**
 * @title GhostFullFlowE2E
 * @notice End-to-end tests for complete Ghost Protocol flows
 * @dev Tests the full lifecycle: bridge → ghost → redeem → partial redeem
 */
contract GhostFullFlowE2E is GhostE2EBase {

    // ============================================================================
    // SCENARIO 1: Basic Full Flow (Bridge → Ghost → Redeem)
    // ============================================================================

    function test_E2E_BasicFullFlow_AliceGhostsBobRedeems() public {
        console2.log("=== E2E: Basic Full Flow ===");
        console2.log("Alice bridges tokens, ghosts them, Bob redeems");

        // Step 1: Alice receives tokens via bridge (simulated)
        uint256 bridgeAmount = 1000e6; // 1000 USDC
        _mintTokens(ghostUSDC, alice, bridgeAmount);
        console2.log("Step 1: Alice bridged", bridgeAmount / 1e6, "USDC");

        _assertBalance(ghostUSDC, alice, bridgeAmount);

        // Step 2: Alice ghosts her tokens
        Voucher memory voucher = _ghost(ghostUSDC, alice, bridgeAmount);
        console2.log("Step 2: Alice ghosted tokens, leaf index:", voucher.leafIndex);

        _assertBalance(ghostUSDC, alice, 0);
        assertEq(ghostUSDC.totalGhosted(), bridgeAmount, "Total ghosted mismatch");

        // Step 3: Bob redeems (breaks the link - anyone can submit!)
        // This is the PRIVACY FEATURE: Bob receives, but relayer submits tx
        uint256 bobBalanceBefore = ghostUSDC.balanceOf(bob);

        _redeem(ghostUSDC, voucher, bob, relayer);
        console2.log("Step 3: Bob redeemed via relayer");

        _assertBalance(ghostUSDC, bob, bobBalanceBefore + bridgeAmount);
        _assertNullifierSpent(voucher.nullifier);
        assertEq(ghostUSDC.totalRedeemed(), bridgeAmount, "Total redeemed mismatch");

        console2.log("=== SUCCESS: Basic flow completed ===");
    }

    // ============================================================================
    // SCENARIO 2: Partial Redemption Flow
    // ============================================================================

    function test_E2E_PartialRedemptionFlow() public {
        console2.log("=== E2E: Partial Redemption Flow ===");

        // Setup: Alice has 1000 USDC
        uint256 totalAmount = 1000e6;
        _mintTokens(ghostUSDC, alice, totalAmount);
        console2.log("Alice starts with", totalAmount / 1e6, "USDC");

        // Step 1: Alice ghosts all tokens
        Voucher memory voucher1 = _ghost(ghostUSDC, alice, totalAmount);
        console2.log("Step 1: Alice ghosted all tokens");

        // Step 2: Alice partially redeems 400 to Bob
        uint256 firstRedeem = 400e6;
        Voucher memory voucher2 = _redeemPartial(ghostUSDC, voucher1, firstRedeem, bob, relayer);
        console2.log("Step 2: Redeemed", firstRedeem / 1e6, "to Bob, remaining:", (totalAmount - firstRedeem) / 1e6);

        _assertBalance(ghostUSDC, bob, firstRedeem);
        _assertNullifierSpent(voucher1.nullifier); // Original nullifier spent
        _assertNullifierNotSpent(voucher2.nullifier); // New voucher's nullifier not spent

        // Step 3: Alice partially redeems 300 to Charlie
        uint256 secondRedeem = 300e6;
        Voucher memory voucher3 = _redeemPartial(ghostUSDC, voucher2, secondRedeem, charlie, relayer);
        console2.log("Step 3: Redeemed", secondRedeem / 1e6, "to Charlie");

        _assertBalance(ghostUSDC, charlie, secondRedeem);
        _assertNullifierSpent(voucher2.nullifier);

        // Step 4: Alice redeems remaining 300 to herself (new wallet)
        address aliceNewWallet = makeAddr("aliceNewWallet");
        uint256 finalRedeem = 300e6;
        _redeem(ghostUSDC, voucher3, aliceNewWallet, relayer);
        console2.log("Step 4: Final redeem to Alice's new wallet");

        _assertBalance(ghostUSDC, aliceNewWallet, finalRedeem);
        _assertNullifierSpent(voucher3.nullifier);

        // Verify total statistics
        (uint256 ghosted, uint256 redeemed, uint256 outstanding) = ghostUSDC.getGhostStats();
        assertEq(ghosted, totalAmount, "Total ghosted should equal original amount");
        assertEq(redeemed, totalAmount, "All should be redeemed");
        assertEq(outstanding, 0, "Nothing outstanding");

        console2.log("=== SUCCESS: Partial redemption flow completed ===");
    }

    // ============================================================================
    // SCENARIO 3: Multi-User Anonymity Set
    // ============================================================================

    function test_E2E_MultiUserAnonymitySet() public {
        console2.log("=== E2E: Multi-User Anonymity Set ===");
        console2.log("Multiple users ghost and redeem, increasing anonymity");

        // Setup: Multiple users bridge tokens
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 500e6;
        amounts[1] = 750e6;
        amounts[2] = 1000e6;

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        address[] memory recipients = new address[](3);
        recipients[0] = makeAddr("recipient1");
        recipients[1] = makeAddr("recipient2");
        recipients[2] = makeAddr("recipient3");

        Voucher[] memory vouchers = new Voucher[](3);

        // Step 1: All users receive and ghost tokens
        for (uint256 i = 0; i < 3; i++) {
            _mintTokens(ghostUSDC, users[i], amounts[i]);
            vouchers[i] = _ghost(ghostUSDC, users[i], amounts[i]);
            console2.log("User ghosted USDC, index:", i);
        }

        // Verify tree state
        assertEq(commitmentTree.getNextLeafIndex(), 3, "Should have 3 commitments");

        // Step 2: All redeem to different addresses (order doesn't matter!)
        // This demonstrates the anonymity - can't tell who ghosted what
        for (uint256 i = 0; i < 3; i++) {
            // All redemptions go through the same relayer
            _redeem(ghostUSDC, vouchers[i], recipients[i], relayer);
            console2.log("Redemption completed, index:", i);
        }

        // Verify all recipients received correct amounts
        for (uint256 i = 0; i < 3; i++) {
            _assertBalance(ghostUSDC, recipients[i], amounts[i]);
        }

        console2.log("=== SUCCESS: Multi-user anonymity set completed ===");
    }

    // ============================================================================
    // SCENARIO 4: Cross-Token Privacy
    // ============================================================================

    function test_E2E_CrossTokenPrivacy() public {
        console2.log("=== E2E: Cross-Token Privacy ===");
        console2.log("Same commitment tree used across different tokens");

        // Alice ghosts USDC
        uint256 usdcAmount = 1000e6;
        _mintTokens(ghostUSDC, alice, usdcAmount);
        Voucher memory usdcVoucher = _ghost(ghostUSDC, alice, usdcAmount);

        // Bob ghosts WETH
        uint256 wethAmount = 2 ether;
        _mintTokens(ghostWETH, bob, wethAmount);
        Voucher memory wethVoucher = _ghost(ghostWETH, bob, wethAmount);

        // Verify shared commitment tree
        assertEq(commitmentTree.getNextLeafIndex(), 2, "Both should share same tree");
        console2.log("Both tokens use shared commitment tree");

        // Redeem to new addresses
        address newAlice = makeAddr("newAlice");
        address newBob = makeAddr("newBob");

        _redeem(ghostUSDC, usdcVoucher, newAlice, relayer);
        _redeem(ghostWETH, wethVoucher, newBob, relayer);

        _assertBalance(ghostUSDC, newAlice, usdcAmount);
        assertEq(ghostWETH.balanceOf(newBob), wethAmount);

        console2.log("=== SUCCESS: Cross-token privacy completed ===");
    }

    // ============================================================================
    // SCENARIO 5: Double-Spend Prevention
    // ============================================================================

    function test_E2E_DoubleSpendPrevention() public {
        console2.log("=== E2E: Double-Spend Prevention ===");

        // Alice ghosts tokens
        uint256 amount = 1000e6;
        _mintTokens(ghostUSDC, alice, amount);
        Voucher memory voucher = _ghost(ghostUSDC, alice, amount);

        // First redemption succeeds
        _redeem(ghostUSDC, voucher, bob, relayer);
        console2.log("First redemption succeeded");

        // Second redemption with same nullifier MUST fail
        bytes32 merkleRoot = commitmentTree.getRoot();
        (bytes32[] memory pathElements, uint256[] memory pathIndices) = _buildMerkleProof(voucher.leafIndex);
        bytes memory zkProof = _generateDummyProof();

        vm.prank(attacker);
        vm.expectRevert(GhostERC20Harness.NullifierAlreadySpent.selector);
        ghostUSDC.redeem(
            voucher.amount,
            attacker,
            voucher.nullifier,
            merkleRoot,
            pathElements,
            pathIndices,
            zkProof
        );
        console2.log("Double-spend correctly prevented");

        console2.log("=== SUCCESS: Double-spend prevention verified ===");
    }

    // ============================================================================
    // SCENARIO 6: Relayer Privacy Model
    // ============================================================================

    function test_E2E_RelayerPrivacyModel() public {
        console2.log("=== E2E: Relayer Privacy Model ===");
        console2.log("Demonstrating that tx submitter is NOT the recipient");

        // Alice ghosts tokens
        uint256 amount = 1000e6;
        _mintTokens(ghostUSDC, alice, amount);
        Voucher memory voucher = _ghost(ghostUSDC, alice, amount);

        // Record balances before
        uint256 relayerBalanceBefore = ghostUSDC.balanceOf(relayer);
        uint256 bobBalanceBefore = ghostUSDC.balanceOf(bob);

        // Relayer submits tx, but Bob receives
        vm.prank(relayer);
        bytes32 merkleRoot = commitmentTree.getRoot();
        (bytes32[] memory pathElements, uint256[] memory pathIndices) = _buildMerkleProof(voucher.leafIndex);

        vm.expectEmit(true, true, true, true);
        emit Redeemed(amount, bob, voucher.nullifier);

        ghostUSDC.redeem(
            voucher.amount,
            bob,
            voucher.nullifier,
            merkleRoot,
            pathElements,
            pathIndices,
            _generateDummyProof()
        );

        // Verify: Bob got tokens, relayer got nothing
        assertEq(ghostUSDC.balanceOf(relayer), relayerBalanceBefore, "Relayer balance unchanged");
        assertEq(ghostUSDC.balanceOf(bob), bobBalanceBefore + amount, "Bob received tokens");

        console2.log("Relayer submitted tx, Bob received tokens");
        console2.log("Observer sees: relayer -> redeem -> bob");
        console2.log("Cannot link to: alice -> ghost");
        console2.log("=== SUCCESS: Relayer privacy model verified ===");
    }

    // ============================================================================
    // SCENARIO 7: Edge Cases
    // ============================================================================

    function test_E2E_EdgeCase_MinimumAmount() public {
        // Ghost and redeem minimum possible amount
        uint256 minAmount = 1; // 1 wei equivalent
        _mintTokens(ghostUSDC, alice, minAmount);

        Voucher memory voucher = _ghost(ghostUSDC, alice, minAmount);
        _redeem(ghostUSDC, voucher, bob, relayer);

        _assertBalance(ghostUSDC, bob, minAmount);
    }

    function test_E2E_EdgeCase_LargeAmount() public {
        // Ghost and redeem very large amount
        uint256 largeAmount = 1_000_000_000e6; // 1 billion USDC
        _mintTokens(ghostUSDC, alice, largeAmount);

        Voucher memory voucher = _ghost(ghostUSDC, alice, largeAmount);
        _redeem(ghostUSDC, voucher, bob, relayer);

        _assertBalance(ghostUSDC, bob, largeAmount);
    }

    function test_E2E_EdgeCase_ImmediateRedeem() public {
        // Ghost and redeem in same block
        uint256 amount = 1000e6;
        _mintTokens(ghostUSDC, alice, amount);

        Voucher memory voucher = _ghost(ghostUSDC, alice, amount);
        _redeem(ghostUSDC, voucher, bob, relayer);

        _assertBalance(ghostUSDC, bob, amount);
    }

    function test_E2E_EdgeCase_DelayedRedeem() public {
        // Ghost now, redeem much later
        uint256 amount = 1000e6;
        _mintTokens(ghostUSDC, alice, amount);

        Voucher memory voucher = _ghost(ghostUSDC, alice, amount);

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Should still work - Merkle root is stored
        _redeem(ghostUSDC, voucher, bob, relayer);

        _assertBalance(ghostUSDC, bob, amount);
    }

    // ============================================================================
    // FUZZ TESTS
    // ============================================================================

    function testFuzz_E2E_GhostRedeemAnyAmount(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1e30); // Reasonable bounds

        _mintTokens(ghostUSDC, alice, amount);
        Voucher memory voucher = _ghost(ghostUSDC, alice, amount);
        _redeem(ghostUSDC, voucher, bob, relayer);

        _assertBalance(ghostUSDC, bob, amount);
    }

    function testFuzz_E2E_PartialRedeemAnyRatio(uint256 total, uint256 firstRedeem) public {
        vm.assume(total > 1 && total <= 1e30);
        vm.assume(firstRedeem > 0 && firstRedeem < total);

        _mintTokens(ghostUSDC, alice, total);
        Voucher memory v1 = _ghost(ghostUSDC, alice, total);
        Voucher memory v2 = _redeemPartial(ghostUSDC, v1, firstRedeem, bob, relayer);

        uint256 remaining = total - firstRedeem;
        _redeem(ghostUSDC, v2, charlie, relayer);

        _assertBalance(ghostUSDC, bob, firstRedeem);
        _assertBalance(ghostUSDC, charlie, remaining);
    }
}
