// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostCommitmentTree} from "../interfaces/IGhostContracts.sol";
import {TestGhostHash} from "./TestGhostHash.sol";

/// @title TestCommitmentTree
/// @notice Keccak-based commitment tree for testing on zkSync testnet
/// @dev This is a TESTING ONLY version that uses keccak256 instead of Poseidon.
///      DO NOT USE IN PRODUCTION - the hashes won't match ZK circuits.
contract TestCommitmentTree is IGhostCommitmentTree {
    uint256 public constant TREE_DEPTH = 20;
    uint256 public constant MAX_LEAVES = 2 ** TREE_DEPTH;
    uint256 public constant ROOT_HISTORY_SIZE = 100;

    uint256 public nextLeafIndex;
    bytes32 public currentRoot;
    bytes32[TREE_DEPTH] public filledSubtrees;
    bytes32[ROOT_HISTORY_SIZE] public roots;
    uint256 public currentRootIndex;
    mapping(bytes32 => bool) public rootHistory;
    bytes32[TREE_DEPTH] public zeros;
    mapping(address => bool) public authorizedInserters;
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

        // Initialize zero values using keccak (much cheaper than Poseidon)
        bytes32 currentZero = TestGhostHash.hashLeaf(bytes32(0));
        zeros[0] = currentZero;

        for (uint256 i = 1; i < TREE_DEPTH; i++) {
            currentZero = TestGhostHash.hashNode(currentZero, currentZero);
            zeros[i] = currentZero;
        }

        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            filledSubtrees[i] = zeros[i];
        }

        currentRoot = TestGhostHash.hashNode(zeros[TREE_DEPTH - 1], zeros[TREE_DEPTH - 1]);
        roots[0] = currentRoot;
        rootHistory[currentRoot] = true;
    }

    function authorizeInserter(address inserter) external onlyOwner {
        authorizedInserters[inserter] = true;
    }

    function revokeInserter(address inserter) external onlyOwner {
        authorizedInserters[inserter] = false;
    }

    function insert(bytes32 commitment) external onlyAuthorized returns (uint256 leafIndex) {
        if (nextLeafIndex >= MAX_LEAVES) {
            revert TreeFull();
        }

        leafIndex = nextLeafIndex;
        nextLeafIndex++;

        bytes32 currentHash = TestGhostHash.hashLeaf(commitment);
        uint256 currentIndex = leafIndex;

        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            if (currentIndex % 2 == 0) {
                filledSubtrees[i] = currentHash;
                currentHash = TestGhostHash.hashNode(currentHash, zeros[i]);
            } else {
                currentHash = TestGhostHash.hashNode(filledSubtrees[i], currentHash);
            }
            currentIndex = currentIndex / 2;
        }

        currentRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        currentRoot = currentHash;
        roots[currentRootIndex] = currentRoot;
        rootHistory[currentRoot] = true;

        emit CommitmentInserted(commitment, leafIndex, currentRoot);
    }

    function getRoot() external view returns (bytes32) {
        return currentRoot;
    }

    function getHistoricalRoot(uint256 rootIndex) external view returns (bytes32) {
        return roots[rootIndex % ROOT_HISTORY_SIZE];
    }

    function isKnownRoot(bytes32 root) external view returns (bool) {
        if (root == bytes32(0)) {
            return false;
        }
        return rootHistory[root];
    }

    function getNextLeafIndex() external view returns (uint256) {
        return nextLeafIndex;
    }

    function verifyProof(
        bytes32 leaf,
        bytes32[] calldata pathElements,
        uint256[] calldata pathIndices,
        bytes32 root
    ) external pure returns (bool) {
        if (pathElements.length != TREE_DEPTH || pathIndices.length != TREE_DEPTH) {
            revert InvalidProofLength();
        }

        bytes32 currentHash = TestGhostHash.hashLeaf(leaf);

        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            if (pathIndices[i] == 0) {
                currentHash = TestGhostHash.hashNode(currentHash, pathElements[i]);
            } else {
                currentHash = TestGhostHash.hashNode(pathElements[i], currentHash);
            }
        }

        return currentHash == root;
    }

    function getZeroValue(uint256 level) external view returns (bytes32) {
        require(level < TREE_DEPTH, "Level out of bounds");
        return zeros[level];
    }

    function getFilledSubtree(uint256 level) external view returns (bytes32) {
        require(level < TREE_DEPTH, "Level out of bounds");
        return filledSubtrees[level];
    }

    function computeHashLeaf(bytes32 value) external pure returns (bytes32) {
        return TestGhostHash.hashLeaf(value);
    }

    function computeHashNode(bytes32 left, bytes32 right) external pure returns (bytes32) {
        return TestGhostHash.hashNode(left, right);
    }

    function computeCommitmentHash(
        bytes32 secret,
        bytes32 nullifier,
        uint256 amount,
        address token
    ) external pure returns (bytes32) {
        return TestGhostHash.computeCommitment(secret, nullifier, amount, token);
    }

    function getAllZeroValues() external view returns (bytes32[TREE_DEPTH] memory) {
        return zeros;
    }

    // =========================================================================
    // Contract Type Discriminator (for deployment verification)
    // =========================================================================

    /// @notice Indicates this is a TEST contract (not production)
    /// @return true for test contracts, false for production contracts
    function isTestContract() external pure returns (bool) {
        return true;
    }

    /// @notice Returns the hash function used by this contract
    /// @return "keccak256" for test, "poseidon" for production
    function hashFunction() external pure returns (string memory) {
        return "keccak256";
    }
}
