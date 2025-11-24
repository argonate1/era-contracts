// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostCommitmentTree} from "./interfaces/IGhostContracts.sol";
import {GhostHash} from "./libraries/GhostHash.sol";

/// @title CommitmentTree
/// @author Ghost Protocol Team
/// @notice Incremental Merkle tree for storing ghost voucher commitments
/// @dev Uses an incremental Merkle tree structure similar to Tornado Cash
///      - Tree depth of 20 supports ~1M commitments (2^20 = 1,048,576)
///      - Stores historical roots to allow proofs against recent states
///      - Gas-efficient incremental updates (~250k gas per insert)
///
/// @custom:security-contact security@ghostprotocol.xyz
///
/// @custom:security-assumptions
///      1. The hash function (Poseidon via GhostHash) is collision-resistant
///      2. Only authorized inserters can add commitments (access control)
///      3. Commitments are unique and cannot be predicted without the secret
///      4. Root history size (100) is sufficient for redemption window
///
/// @custom:invariants
///      1. nextLeafIndex monotonically increases and never exceeds MAX_LEAVES
///      2. Once a root is added to rootHistory, it remains valid forever
///      3. currentRoot always equals roots[currentRootIndex]
///      4. filledSubtrees[i] contains the rightmost non-zero node at level i
///      5. All historical roots can verify proofs for commitments inserted before them
///
/// @custom:audit-notes
///      - DO NOT MODIFY: Hash function implementation in GhostHash library
///      - DO NOT MODIFY: Zero value initialization logic
///      - CRITICAL: Root history persistence is essential for privacy
contract CommitmentTree is IGhostCommitmentTree {
    /// @notice Depth of the Merkle tree
    uint256 public constant TREE_DEPTH = 20;

    /// @notice Maximum number of leaves (2^20 = 1,048,576)
    uint256 public constant MAX_LEAVES = 2 ** TREE_DEPTH;

    /// @notice Number of historical roots to store
    uint256 public constant ROOT_HISTORY_SIZE = 100;

    /// @notice The index of the next leaf to be inserted
    uint256 public nextLeafIndex;

    /// @notice The current root of the tree
    bytes32 public currentRoot;

    /// @notice Filled subtrees at each level
    /// @dev filledSubtrees[i] is the rightmost non-zero node at level i
    bytes32[TREE_DEPTH] public filledSubtrees;

    /// @notice Historical roots for proof verification
    bytes32[ROOT_HISTORY_SIZE] public roots;

    /// @notice Index of the current root in the history
    uint256 public currentRootIndex;

    /// @notice Map of known roots for O(1) lookup
    mapping(bytes32 => bool) public rootHistory;

    /// @notice Zero values for each level (precomputed)
    /// @dev zeros[i] is the zero value at height i
    bytes32[TREE_DEPTH] public zeros;

    /// @notice Authorized contracts that can insert commitments
    mapping(address => bool) public authorizedInserters;

    /// @notice Owner address for authorization management
    address public owner;

    error TreeFull();
    error UnknownRoot();
    error Unauthorized();
    error InvalidProofLength();

    modifier onlyAuthorized() {
        if (!authorizedInserters[msg.sender] && msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }

    constructor() {
        owner = msg.sender;
        authorizedInserters[msg.sender] = true;

        // Initialize zero values for each level
        // zeros[0] is the hash of an empty leaf
        bytes32 currentZero = GhostHash.hashLeaf(bytes32(0));
        zeros[0] = currentZero;

        for (uint256 i = 1; i < TREE_DEPTH; i++) {
            currentZero = GhostHash.hashNode(currentZero, currentZero);
            zeros[i] = currentZero;
        }

        // Initialize filled subtrees with zeros
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            filledSubtrees[i] = zeros[i];
        }

        // Compute initial root (all zeros)
        currentRoot = GhostHash.hashNode(zeros[TREE_DEPTH - 1], zeros[TREE_DEPTH - 1]);
        roots[0] = currentRoot;
        rootHistory[currentRoot] = true;
    }

    /// @notice Authorize an address to insert commitments
    /// @param inserter The address to authorize
    function authorizeInserter(address inserter) external onlyOwner {
        authorizedInserters[inserter] = true;
    }

    /// @notice Revoke authorization from an address
    /// @param inserter The address to revoke
    function revokeInserter(address inserter) external onlyOwner {
        authorizedInserters[inserter] = false;
    }

    /// @inheritdoc IGhostCommitmentTree
    /// @notice Insert a new commitment into the Merkle tree
    /// @dev Gas cost: ~250,000 gas (varies slightly based on tree state)
    ///      This function performs an incremental update, only recomputing
    ///      the path from the new leaf to the root (O(log n) hashes).
    ///
    ///      Algorithm:
    ///      1. Assign next available leaf index
    ///      2. Hash commitment as leaf: H(commitment)
    ///      3. For each level i from 0 to TREE_DEPTH-1:
    ///         - If index is even (left child): update filledSubtrees[i], hash with zeros[i]
    ///         - If index is odd (right child): hash with filledSubtrees[i]
    ///      4. Store new root in circular buffer and mark as known
    ///
    /// @param commitment The commitment to insert (typically hash(secret, nullifier, amount, token))
    /// @return leafIndex The index at which the commitment was inserted (0-indexed)
    ///
    /// @custom:security The commitment should be computed client-side to protect the secret.
    ///                  Never pass raw secrets to this function.
    /// @custom:gas-optimization Uses incremental updates instead of full tree rebuild
    function insert(bytes32 commitment) external onlyAuthorized returns (uint256 leafIndex) {
        if (nextLeafIndex >= MAX_LEAVES) {
            revert TreeFull();
        }

        leafIndex = nextLeafIndex;
        // slither-disable-next-line weak-prng
        nextLeafIndex++;

        // Hash the commitment as a leaf
        bytes32 currentHash = GhostHash.hashLeaf(commitment);
        uint256 currentIndex = leafIndex;

        // Update the path from leaf to root
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            if (currentIndex % 2 == 0) {
                // Left child - sibling is a zero or filled subtree
                // Update filled subtree at this level
                filledSubtrees[i] = currentHash;
                // Sibling is a zero value
                currentHash = GhostHash.hashNode(currentHash, zeros[i]);
            } else {
                // Right child - sibling is the filled subtree
                currentHash = GhostHash.hashNode(filledSubtrees[i], currentHash);
            }
            currentIndex = currentIndex / 2;
        }

        // Update root history (circular buffer)
        currentRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        currentRoot = currentHash;
        roots[currentRootIndex] = currentRoot;
        rootHistory[currentRoot] = true;

        emit CommitmentInserted(commitment, leafIndex, currentRoot);
    }

    /// @inheritdoc IGhostCommitmentTree
    function getRoot() external view returns (bytes32) {
        return currentRoot;
    }

    /// @inheritdoc IGhostCommitmentTree
    function getHistoricalRoot(uint256 rootIndex) external view returns (bytes32) {
        return roots[rootIndex % ROOT_HISTORY_SIZE];
    }

    /// @inheritdoc IGhostCommitmentTree
    function isKnownRoot(bytes32 root) external view returns (bool) {
        if (root == bytes32(0)) {
            return false;
        }
        return rootHistory[root];
    }

    /// @inheritdoc IGhostCommitmentTree
    function getNextLeafIndex() external view returns (uint256) {
        return nextLeafIndex;
    }

    /// @inheritdoc IGhostCommitmentTree
    function verifyProof(
        bytes32 leaf,
        bytes32[] calldata pathElements,
        uint256[] calldata pathIndices,
        bytes32 root
    ) external pure returns (bool) {
        if (pathElements.length != TREE_DEPTH || pathIndices.length != TREE_DEPTH) {
            revert InvalidProofLength();
        }

        bytes32 currentHash = GhostHash.hashLeaf(leaf);

        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            if (pathIndices[i] == 0) {
                // Current node is left child
                currentHash = GhostHash.hashNode(currentHash, pathElements[i]);
            } else {
                // Current node is right child
                currentHash = GhostHash.hashNode(pathElements[i], currentHash);
            }
        }

        return currentHash == root;
    }

    /// @notice Get the zero value at a specific level
    /// @param level The level in the tree
    /// @return The zero value at that level
    function getZeroValue(uint256 level) external view returns (bytes32) {
        require(level < TREE_DEPTH, "Level out of bounds");
        return zeros[level];
    }

    /// @notice Get the filled subtree at a specific level
    /// @param level The level in the tree
    /// @return The filled subtree value at that level
    function getFilledSubtree(uint256 level) external view returns (bytes32) {
        require(level < TREE_DEPTH, "Level out of bounds");
        return filledSubtrees[level];
    }

    // =========================================================================
    // Public Hash Functions (for SDK compatibility)
    // =========================================================================

    /// @notice Compute hash of a leaf value (exposed for SDK use)
    /// @param value The value to hash
    /// @return The hashed value
    function computeHashLeaf(bytes32 value) external pure returns (bytes32) {
        return GhostHash.hashLeaf(value);
    }

    /// @notice Compute hash of two nodes (exposed for SDK use)
    /// @param left Left child hash
    /// @param right Right child hash
    /// @return The parent node hash
    function computeHashNode(bytes32 left, bytes32 right) external pure returns (bytes32) {
        return GhostHash.hashNode(left, right);
    }

    /// @notice Compute commitment hash (exposed for SDK use)
    /// @param secret The secret
    /// @param nullifier The nullifier
    /// @param amount The amount
    /// @param token The token address
    /// @return The commitment hash
    function computeCommitmentHash(
        bytes32 secret,
        bytes32 nullifier,
        uint256 amount,
        address token
    ) external pure returns (bytes32) {
        return GhostHash.computeCommitment(secret, nullifier, amount, token);
    }

    /// @notice Get all zero values at once (for SDK initialization)
    /// @return Array of zero values for levels 0 to TREE_DEPTH-1
    function getAllZeroValues() external view returns (bytes32[TREE_DEPTH] memory) {
        return zeros;
    }
}
