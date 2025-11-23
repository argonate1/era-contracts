pragma circom 2.1.6;

include "./poseidon.circom";
include "./merkle.circom";
include "node_modules/circomlib/circuits/comparators.circom";

// =============================================================================
// GHOST PARTIAL REDEMPTION CIRCUIT
// =============================================================================
// This circuit proves:
// 1. The prover knows a valid commitment in the Merkle tree
// 2. The prover knows the secret and nullifier for the original commitment
// 3. The original commitment matches the claimed original amount
// 4. redeemAmount <= originalAmount (partial or full redemption)
// 5. A new commitment is correctly formed for the remaining balance
//
// PUBLIC INPUTS:
// - merkleRoot: The Merkle root of the commitment tree
// - oldNullifier: The nullifier of the commitment being partially redeemed
// - redeemAmount: The amount being redeemed now
// - tokenAddress: The token being redeemed
// - recipient: The address receiving the tokens
// - originalAmount: The original amount in the commitment
// - newCommitment: The new commitment for remaining balance (if any)
//
// PRIVATE INPUTS:
// - oldSecret: The secret for the original commitment
// - newSecret: Random secret for the new commitment (if partial)
// - newNullifier: Nullifier for the new commitment (if partial)
// - pathElements: Merkle path siblings
// - pathIndices: Merkle path direction indicators
// =============================================================================

template GhostRedeemPartial(levels) {
    // =========================================================================
    // PUBLIC INPUTS
    // =========================================================================
    signal input merkleRoot;
    signal input oldNullifier;      // Revealed to prevent double-spend on original
    signal input redeemAmount;      // Amount being redeemed now
    signal input tokenAddress;
    signal input recipient;
    signal input originalAmount;    // Original amount in the commitment
    signal input newCommitment;     // Commitment for remaining balance (0 if full redeem)

    // =========================================================================
    // PRIVATE INPUTS
    // =========================================================================
    signal input oldSecret;         // Secret for original commitment
    signal input newSecret;         // Secret for new commitment (can be 0 if full redeem)
    signal input newNullifier;      // Nullifier for new commitment (can be 0 if full redeem)
    signal input pathElements[levels];
    signal input pathIndices[levels];

    // =========================================================================
    // STEP 1: Compute the original commitment
    // =========================================================================
    component oldCommitmentHasher = GhostCommitment();
    oldCommitmentHasher.secret <== oldSecret;
    oldCommitmentHasher.nullifier <== oldNullifier;
    oldCommitmentHasher.amount <== originalAmount;
    oldCommitmentHasher.tokenAddress <== tokenAddress;

    // =========================================================================
    // STEP 2: Verify the original commitment exists in the Merkle tree
    // =========================================================================
    component merkleChecker = MerkleTreeChecker(levels);
    merkleChecker.leaf <== oldCommitmentHasher.commitment;
    for (var i = 0; i < levels; i++) {
        merkleChecker.pathElements[i] <== pathElements[i];
        merkleChecker.pathIndices[i] <== pathIndices[i];
    }
    merkleChecker.root <== merkleRoot;

    // =========================================================================
    // STEP 3: Verify redeemAmount <= originalAmount
    // =========================================================================
    component lte = LessEqThan(252); // 252 bits is enough for any token amount
    lte.in[0] <== redeemAmount;
    lte.in[1] <== originalAmount;
    lte.out === 1;

    // =========================================================================
    // STEP 4: Compute remaining amount
    // =========================================================================
    signal remainingAmount;
    remainingAmount <== originalAmount - redeemAmount;

    // =========================================================================
    // STEP 5: Verify new commitment is correct (if there's remaining balance)
    // =========================================================================
    // Compute what the new commitment should be
    component newCommitmentHasher = GhostCommitment();
    newCommitmentHasher.secret <== newSecret;
    newCommitmentHasher.nullifier <== newNullifier;
    newCommitmentHasher.amount <== remainingAmount;
    newCommitmentHasher.tokenAddress <== tokenAddress;

    // If remainingAmount > 0, newCommitment must match
    // If remainingAmount == 0, newCommitment should be 0
    component isZeroRemaining = IsZero();
    isZeroRemaining.in <== remainingAmount;

    // newCommitment = isZeroRemaining ? 0 : computedNewCommitment
    signal expectedNewCommitment;
    expectedNewCommitment <== (1 - isZeroRemaining.out) * newCommitmentHasher.commitment;

    // Verify the provided newCommitment matches expected
    newCommitment === expectedNewCommitment;

    // =========================================================================
    // STEP 6: Bind proof to recipient
    // =========================================================================
    signal recipientSquare;
    recipientSquare <== recipient * recipient;

    // =========================================================================
    // OUTPUT SIGNALS
    // =========================================================================
    signal output oldCommitmentOut;
    signal output newCommitmentOut;
    signal output remainingAmountOut;

    oldCommitmentOut <== oldCommitmentHasher.commitment;
    newCommitmentOut <== newCommitmentHasher.commitment;
    remainingAmountOut <== remainingAmount;
}

// Instantiate with 20 levels
component main {public [merkleRoot, oldNullifier, redeemAmount, tokenAddress, recipient, originalAmount, newCommitment]} = GhostRedeemPartial(20);
