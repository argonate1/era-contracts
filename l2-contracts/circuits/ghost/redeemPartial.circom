pragma circom 2.1.6;

include "./poseidon.circom";
include "./merkle.circom";
include "node_modules/circomlib/circuits/comparators.circom";

// =============================================================================
// GHOST PARTIAL REDEMPTION CIRCUIT
// =============================================================================
// This circuit proves:
// 1. The prover knows a valid commitment in the Merkle tree
// 2. The prover knows the secret for the original commitment
// 3. The original nullifier is correctly derived from (oldSecret, oldLeafIndex)
// 4. The original commitment matches the claimed original amount
// 5. redeemAmount <= originalAmount (partial or full redemption)
// 6. A new commitment is correctly formed for the remaining balance
//
// PUBLIC INPUTS:
// - merkleRoot: The Merkle root of the commitment tree
// - oldNullifier: Hash of (oldSecret, oldLeafIndex) for double-spend prevention
// - redeemAmount: The amount being redeemed now
// - tokenAddress: The token being redeemed
// - recipient: The address receiving the tokens
// - originalAmount: The original amount in the commitment
// - newCommitment: The new commitment for remaining balance (if any)
//
// PRIVATE INPUTS:
// - oldSecret: The secret for the original commitment
// - oldLeafIndex: Position of original commitment in tree (for nullifier derivation)
// - newSecret: Random secret for the new commitment (if partial)
// - newNullifier: Nullifier for the new commitment (if partial)
// - pathElements: Merkle path siblings
// - pathIndices: Merkle path direction indicators
//
// SECURITY: The oldNullifier MUST be derived from (oldSecret, oldLeafIndex) to
// prevent malicious provers from using arbitrary nullifiers for double-spend.
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
    signal input oldLeafIndex;      // Position in tree - used for nullifier derivation
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
    // STEP 3: Verify oldNullifier derivation (CRITICAL SECURITY CONSTRAINT)
    // The oldNullifier MUST be derived from (oldSecret, oldLeafIndex) to prevent
    // malicious provers from using arbitrary nullifiers for double-spend.
    // oldNullifier = Poseidon2(oldSecret, oldLeafIndex)
    // =========================================================================
    component oldNullifierHasher = NullifierHash();
    oldNullifierHasher.secret <== oldSecret;
    oldNullifierHasher.leafIndex <== oldLeafIndex;

    // CRITICAL: Constrain public oldNullifier to equal computed value
    oldNullifier === oldNullifierHasher.hash;

    // =========================================================================
    // STEP 4: Verify redeemAmount <= originalAmount
    // =========================================================================
    component lte = LessEqThan(252); // 252 bits is enough for any token amount
    lte.in[0] <== redeemAmount;
    lte.in[1] <== originalAmount;
    lte.out === 1;

    // =========================================================================
    // STEP 5: Compute remaining amount
    // =========================================================================
    signal remainingAmount;
    remainingAmount <== originalAmount - redeemAmount;

    // =========================================================================
    // STEP 6: Verify new commitment is correct (if there's remaining balance)
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
    // STEP 7: Bind proof to recipient
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
