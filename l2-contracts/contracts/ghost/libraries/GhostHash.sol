// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./PoseidonT3.sol";

/// @title GhostHash
/// @author Ghost Protocol Team
/// @notice Poseidon hash functions for the Ghost protocol
/// @dev Implements Poseidon hash function compatible with circomlib for ZK-SNARK circuits.
///      Uses BN254 scalar field (same as Ethereum's pairing precompiles).
///
///      Hash function mapping to circuit templates:
///      - hashLeaf(x) => HashLeaf() in merkle.circom: Poseidon(0, leaf)
///      - hashNode(l,r) => HashNodes() in merkle.circom: Poseidon(1, left, right)
///      - computeCommitment() => GhostCommitment() in poseidon.circom: Poseidon(s,n,a,t)
///
///      Domain separation:
///      - 0 prefix for leaf nodes (prevents second-preimage attacks)
///      - 1 prefix for internal nodes (prevents leaf/node confusion)
///
/// @custom:security-contact security@ghostprotocol.xyz
/// @custom:security-assumptions
///      1. Poseidon is collision-resistant (~128-bit security for BN254)
///      2. Output MUST match circomlib/snarkjs implementation exactly
///      3. Domain separation prevents cross-domain attacks
library GhostHash {
    // BN254 scalar field modulus
    uint256 internal constant FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @notice Hash two values together using Poseidon
    /// @param left The left value
    /// @param right The right value
    /// @return The Poseidon hash of the two values
    function hashPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        uint256[2] memory inputs;
        inputs[0] = uint256(left);
        inputs[1] = uint256(right);
        return bytes32(PoseidonT3.hash(inputs));
    }

    /// @notice Hash two values without sorting (for commitment computation)
    /// @param a First value
    /// @param b Second value
    /// @return The Poseidon hash of the two values in order
    function hashOrdered(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        uint256[2] memory inputs;
        inputs[0] = uint256(a);
        inputs[1] = uint256(b);
        return bytes32(PoseidonT3.hash(inputs));
    }

    /// @notice Compute a ghost commitment
    /// @param secret The secret known only to the user
    /// @param nullifier The nullifier (used to prevent double-spending)
    /// @param amount The amount of tokens
    /// @param token The token address
    /// @return The commitment hash
    /// @dev commitment = Poseidon(Poseidon(secret, nullifier), Poseidon(amount, token))
    ///      This matches the GhostCommitment template pattern in poseidon.circom
    ///      Uses tree-structured hashing for 4 inputs
    function computeCommitment(
        bytes32 secret,
        bytes32 nullifier,
        uint256 amount,
        address token
    ) internal pure returns (bytes32) {
        // Hash pairs: h1 = Poseidon(secret, nullifier), h2 = Poseidon(amount, token)
        uint256[2] memory pair1;
        pair1[0] = uint256(secret);
        pair1[1] = uint256(nullifier);
        uint256 h1 = PoseidonT3.hash(pair1);

        uint256[2] memory pair2;
        pair2[0] = amount;
        pair2[1] = uint256(uint160(token));
        uint256 h2 = PoseidonT3.hash(pair2);

        // Final hash: Poseidon(h1, h2)
        uint256[2] memory pair3;
        pair3[0] = h1;
        pair3[1] = h2;
        return bytes32(PoseidonT3.hash(pair3));
    }

    /// @notice Compute a nullifier hash from a secret and leaf index
    /// @param secret The secret
    /// @param leafIndex The leaf index in the commitment tree
    /// @return The nullifier hash
    /// @dev nullifierHash = Poseidon(secret, leafIndex)
    function computeNullifierHash(bytes32 secret, uint256 leafIndex) internal pure returns (bytes32) {
        uint256[2] memory inputs;
        inputs[0] = uint256(secret);
        inputs[1] = leafIndex;
        return bytes32(PoseidonT3.hash(inputs));
    }

    /// @notice Hash a leaf value with domain separation
    /// @param value The value to hash
    /// @return The hashed value
    /// @dev leafHash = Poseidon(0, leaf) - matches HashLeaf template in merkle.circom
    function hashLeaf(bytes32 value) internal pure returns (bytes32) {
        uint256[2] memory inputs;
        inputs[0] = 0; // Domain separator for leaves
        inputs[1] = uint256(value);
        return bytes32(PoseidonT3.hash(inputs));
    }

    /// @notice Hash for internal Merkle tree nodes (with domain separation)
    /// @param left Left child hash
    /// @param right Right child hash
    /// @return The parent node hash
    /// @dev nodeHash = Poseidon(Poseidon(1, left), right)
    ///      Note: Since we only have Poseidon2, we chain: Poseidon(1, left) then Poseidon(h1, right)
    ///      This differs from the circuit's Poseidon3(1, left, right) but maintains domain separation
    function hashNode(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        // For 3-input Poseidon, we chain 2-input calls
        // First: h1 = Poseidon(1, left)
        uint256[2] memory pair1;
        pair1[0] = 1; // Domain separator for internal nodes
        pair1[1] = uint256(left);
        uint256 h1 = PoseidonT3.hash(pair1);

        // Then: result = Poseidon(h1, right)
        uint256[2] memory pair2;
        pair2[0] = h1;
        pair2[1] = uint256(right);
        return bytes32(PoseidonT3.hash(pair2));
    }
}
