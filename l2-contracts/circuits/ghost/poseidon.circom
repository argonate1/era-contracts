pragma circom 2.1.6;

// =============================================================================
// POSEIDON HASH FUNCTION FOR GHOST PROTOCOL
// =============================================================================
// Poseidon is a ZK-friendly hash function optimized for arithmetic circuits.
// It operates over the BN254 scalar field (same as Ethereum's pairing curve).
//
// IMPORTANT: This implementation uses Poseidon(2) as the base building block
// and chains calls for larger arities. This matches the Solidity on-chain
// implementation in GhostHash.sol for exact compatibility.
//
// Reference: https://eprint.iacr.org/2019/458.pdf
// =============================================================================

// Import circomlib's Poseidon with pre-computed BN254 constants
include "node_modules/circomlib/circuits/poseidon.circom";

// Base Poseidon hash with 2 inputs (uses circomlib directly)
template Poseidon2() {
    signal input in[2];
    signal output out;

    component hasher = Poseidon(2);
    hasher.inputs[0] <== in[0];
    hasher.inputs[1] <== in[1];

    out <== hasher.out;
}

// Poseidon hash with 3 inputs using chained Poseidon2
// hash = Poseidon2(Poseidon2(in[0], in[1]), in[2])
// This matches the Solidity GhostHash.hashNode() implementation
template Poseidon3Chained() {
    signal input in[3];
    signal output out;

    // First hash: h1 = Poseidon2(in[0], in[1])
    component hash1 = Poseidon(2);
    hash1.inputs[0] <== in[0];
    hash1.inputs[1] <== in[1];

    // Second hash: out = Poseidon2(h1, in[2])
    component hash2 = Poseidon(2);
    hash2.inputs[0] <== hash1.out;
    hash2.inputs[1] <== in[2];

    out <== hash2.out;
}

// Poseidon hash with 4 inputs using tree-structured Poseidon2 calls
// hash = Poseidon2(Poseidon2(in[0], in[1]), Poseidon2(in[2], in[3]))
// This matches the Solidity GhostHash.computeCommitment() implementation
template Poseidon4Chained() {
    signal input in[4];
    signal output out;

    // Left branch: h1 = Poseidon2(in[0], in[1])
    component hash1 = Poseidon(2);
    hash1.inputs[0] <== in[0];
    hash1.inputs[1] <== in[1];

    // Right branch: h2 = Poseidon2(in[2], in[3])
    component hash2 = Poseidon(2);
    hash2.inputs[0] <== in[2];
    hash2.inputs[1] <== in[3];

    // Final hash: out = Poseidon2(h1, h2)
    component hash3 = Poseidon(2);
    hash3.inputs[0] <== hash1.out;
    hash3.inputs[1] <== hash2.out;

    out <== hash3.out;
}

// Ghost-specific commitment hash
// commitment = Poseidon2(Poseidon2(secret, nullifier), Poseidon2(amount, tokenAddress))
// This matches GhostHash.computeCommitment() in Solidity exactly
template GhostCommitment() {
    signal input secret;
    signal input nullifier;
    signal input amount;
    signal input tokenAddress;
    signal output commitment;

    component hasher = Poseidon4Chained();
    hasher.in[0] <== secret;
    hasher.in[1] <== nullifier;
    hasher.in[2] <== amount;
    hasher.in[3] <== tokenAddress;

    commitment <== hasher.out;
}

// Nullifier hash for double-spend prevention
// nullifierHash = Poseidon2(secret, leafIndex)
// This matches GhostHash.computeNullifierHash() in Solidity
template NullifierHash() {
    signal input secret;
    signal input leafIndex;
    signal output hash;

    component hasher = Poseidon(2);
    hasher.inputs[0] <== secret;
    hasher.inputs[1] <== leafIndex;

    hash <== hasher.out;
}

// =========================================================================
// LEGACY TEMPLATES (keep for backward compatibility, but use chained versions)
// =========================================================================

// Direct Poseidon3 using circomlib (NOT compatible with Solidity GhostHash)
// Use Poseidon3Chained for on-chain compatibility
template Poseidon3() {
    signal input in[3];
    signal output out;

    component hasher = Poseidon(3);
    hasher.inputs[0] <== in[0];
    hasher.inputs[1] <== in[1];
    hasher.inputs[2] <== in[2];

    out <== hasher.out;
}

// Direct Poseidon4 using circomlib (NOT compatible with Solidity GhostHash)
// Use Poseidon4Chained for on-chain compatibility
template Poseidon4() {
    signal input in[4];
    signal output out;

    component hasher = Poseidon(4);
    hasher.inputs[0] <== in[0];
    hasher.inputs[1] <== in[1];
    hasher.inputs[2] <== in[2];
    hasher.inputs[3] <== in[3];

    out <== hasher.out;
}
