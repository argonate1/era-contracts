pragma circom 2.1.6;

include "./poseidon.circom";

// =============================================================================
// MERKLE TREE COMPONENTS FOR GHOST PROTOCOL
// =============================================================================
// Implements Merkle tree verification for the commitment tree.
// Uses chained Poseidon2 hash for compatibility with Solidity GhostHash.sol.
// Tree depth: 20 levels (~1M commitments)
//
// IMPORTANT: All hash functions use Poseidon2-based implementations that
// exactly match the on-chain GhostHash library.
// =============================================================================

// Hash a leaf with domain separation
// leafHash = Poseidon2(0, leaf)
// Matches GhostHash.hashLeaf() in Solidity
template HashLeaf() {
    signal input leaf;
    signal output hash;

    component hasher = Poseidon(2);
    hasher.inputs[0] <== 0; // Domain separator for leaves
    hasher.inputs[1] <== leaf;

    hash <== hasher.out;
}

// Hash two nodes with domain separation using chained Poseidon2
// nodeHash = Poseidon2(Poseidon2(1, left), right)
// Matches GhostHash.hashNode() in Solidity exactly
template HashNodes() {
    signal input left;
    signal input right;
    signal output hash;

    // First: h1 = Poseidon2(1, left) - domain separator
    component hash1 = Poseidon(2);
    hash1.inputs[0] <== 1; // Domain separator for internal nodes
    hash1.inputs[1] <== left;

    // Second: hash = Poseidon2(h1, right)
    component hash2 = Poseidon(2);
    hash2.inputs[0] <== hash1.out;
    hash2.inputs[1] <== right;

    hash <== hash2.out;
}

// Selector: if pathIndex == 0, output (in, sibling), else (sibling, in)
template DualMux() {
    signal input in;
    signal input sibling;
    signal input pathIndex; // 0 or 1
    signal output left;
    signal output right;

    // pathIndex must be 0 or 1
    pathIndex * (1 - pathIndex) === 0;

    // If pathIndex == 0: left = in, right = sibling
    // If pathIndex == 1: left = sibling, right = in
    left <== in + pathIndex * (sibling - in);
    right <== sibling + pathIndex * (in - sibling);
}

// Single level of Merkle tree verification
template MerkleLevel() {
    signal input currentHash;
    signal input sibling;
    signal input pathIndex;
    signal output nextHash;

    component mux = DualMux();
    mux.in <== currentHash;
    mux.sibling <== sibling;
    mux.pathIndex <== pathIndex;

    component hasher = HashNodes();
    hasher.left <== mux.left;
    hasher.right <== mux.right;

    nextHash <== hasher.hash;
}

// Full Merkle tree membership proof
// Verifies that a leaf exists in a Merkle tree with given root
template MerkleTreeChecker(levels) {
    signal input leaf;
    signal input pathElements[levels];
    signal input pathIndices[levels];
    signal input root;

    // Hash the leaf with domain separation
    component leafHasher = HashLeaf();
    leafHasher.leaf <== leaf;

    // Process each level
    component levels_[levels];

    for (var i = 0; i < levels; i++) {
        levels_[i] = MerkleLevel();

        if (i == 0) {
            levels_[i].currentHash <== leafHasher.hash;
        } else {
            levels_[i].currentHash <== levels_[i-1].nextHash;
        }

        levels_[i].sibling <== pathElements[i];
        levels_[i].pathIndex <== pathIndices[i];
    }

    // Final hash must equal the root
    root === levels_[levels-1].nextHash;
}

// Compute Merkle root from leaf and path (for verification)
template MerkleRootComputer(levels) {
    signal input leaf;
    signal input pathElements[levels];
    signal input pathIndices[levels];
    signal output root;

    // Hash the leaf with domain separation
    component leafHasher = HashLeaf();
    leafHasher.leaf <== leaf;

    // Process each level
    component levels_[levels];

    for (var i = 0; i < levels; i++) {
        levels_[i] = MerkleLevel();

        if (i == 0) {
            levels_[i].currentHash <== leafHasher.hash;
        } else {
            levels_[i].currentHash <== levels_[i-1].nextHash;
        }

        levels_[i].sibling <== pathElements[i];
        levels_[i].pathIndex <== pathIndices[i];
    }

    root <== levels_[levels-1].nextHash;
}
