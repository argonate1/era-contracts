// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TestGhostHash
/// @notice Keccak-based hash functions for testing Ghost protocol on zkSync testnet
/// @dev This is a TESTING ONLY version that uses keccak256 instead of Poseidon.
///      DO NOT USE IN PRODUCTION - this does not match the ZK circuits.
library TestGhostHash {
    /// @notice Hash two values together using keccak256
    function hashPair(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    /// @notice Hash two values without sorting
    function hashOrdered(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    /// @notice Compute a ghost commitment (test version)
    function computeCommitment(
        bytes32 secret,
        bytes32 nullifier,
        uint256 amount,
        address token
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(secret, nullifier, amount, token));
    }

    /// @notice Compute a nullifier hash
    function computeNullifierHash(bytes32 secret, uint256 leafIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(secret, leafIndex));
    }

    /// @notice Hash a leaf value with domain separation
    function hashLeaf(bytes32 value) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), value));
    }

    /// @notice Hash for internal Merkle tree nodes
    function hashNode(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(uint256(1)), left, right));
    }
}
