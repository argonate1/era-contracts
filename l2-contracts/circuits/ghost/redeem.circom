pragma circom 2.1.6;

include "./poseidon.circom";
include "./merkle.circom";

// =============================================================================
// GHOST REDEMPTION CIRCUIT
// =============================================================================
// This circuit proves:
// 1. The prover knows a valid commitment in the Merkle tree
// 2. The prover knows the secret that created the commitment
// 3. The commitment matches the claimed amount and token
// 4. The proof is bound to a specific recipient (prevents front-running)
//
// PUBLIC INPUTS:
// - merkleRoot: The Merkle root of the commitment tree
// - nullifier: Random value included in commitment for double-spend prevention
// - amount: The amount being redeemed
// - tokenAddress: The token being redeemed
// - recipient: The address receiving the tokens
//
// PRIVATE INPUTS:
// - secret: The random secret known only to the voucher holder
// - pathElements: Merkle path siblings
// - pathIndices: Merkle path direction indicators
//
// SECURITY: The nullifier is a random value stored in the commitment. When
// revealed at redeem time, the contract tracks it to prevent double-spending.
// This follows the Tornado Cash design pattern where nullifier is random.
// =============================================================================

template GhostRedeem(levels) {
    // =========================================================================
    // PUBLIC INPUTS
    // =========================================================================
    signal input merkleRoot;
    signal input nullifier;         // Revealed to prevent double-spend
    signal input amount;
    signal input tokenAddress;
    signal input recipient;         // Included to bind proof to specific recipient

    // =========================================================================
    // PRIVATE INPUTS (known only to the prover)
    // =========================================================================
    signal input secret;            // Random secret - never revealed
    signal input pathElements[levels];
    signal input pathIndices[levels];

    // =========================================================================
    // STEP 1: Compute the commitment from private inputs
    // commitment = Poseidon(secret, nullifier, amount, tokenAddress)
    // =========================================================================
    component commitmentHasher = GhostCommitment();
    commitmentHasher.secret <== secret;
    commitmentHasher.nullifier <== nullifier;
    commitmentHasher.amount <== amount;
    commitmentHasher.tokenAddress <== tokenAddress;

    // =========================================================================
    // STEP 2: Verify the commitment exists in the Merkle tree
    // =========================================================================
    component merkleChecker = MerkleTreeChecker(levels);
    merkleChecker.leaf <== commitmentHasher.commitment;
    for (var i = 0; i < levels; i++) {
        merkleChecker.pathElements[i] <== pathElements[i];
        merkleChecker.pathIndices[i] <== pathIndices[i];
    }
    merkleChecker.root <== merkleRoot;

    // =========================================================================
    // STEP 3: Bind proof to recipient (prevents front-running)
    // We include recipient in the circuit to ensure the proof can only be
    // used to send tokens to the specified recipient
    // =========================================================================
    // The recipient is constrained by being a public input
    // Any attempt to change recipient will invalidate the proof
    signal recipientSquare;
    recipientSquare <== recipient * recipient;
    // This constraint ensures recipient is actually used in the circuit

    // =========================================================================
    // OUTPUT SIGNALS (for debugging, not part of proof)
    // =========================================================================
    signal output commitmentOut;
    commitmentOut <== commitmentHasher.commitment;
}

// Instantiate with 20 levels (supports ~1M commitments)
component main {public [merkleRoot, nullifier, amount, tokenAddress, recipient]} = GhostRedeem(20);
