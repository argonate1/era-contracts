// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostCommitmentTree} from "../interfaces/IGhostContracts.sol";

/// @title TestCommitmentTree
/// @notice Simple Merkle tree for testing using keccak256
/// @dev Uses keccak256 instead of Poseidon for ZKsync deployment compatibility
contract TestCommitmentTree is IGhostCommitmentTree {
    uint256 public constant TREE_DEPTH = 20;
    uint256 public constant MAX_LEAVES = 2 ** TREE_DEPTH;

    // Root history for nullifier checking
    uint256 public constant ROOT_HISTORY_SIZE = 100;
    bytes32[100] public rootHistory;
    uint256 public currentRootIndex;

    // Tree state
    bytes32 public currentRoot;
    uint256 public nextLeafIndex;
    bytes32[20] public filledSubtrees;

    // Access control
    mapping(address => bool) public authorizedInserters;
    address public owner;

    // Zero values for empty tree levels (keccak256 based)
    bytes32[21] public zeros;

    error Unauthorized();
    error TreeFull();
    error InvalidProof();

    modifier onlyAuthorized() {
        if (!authorizedInserters[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;

        // Initialize zero values using keccak256
        zeros[0] = keccak256(abi.encodePacked(uint256(0)));
        for (uint256 i = 1; i <= TREE_DEPTH; i++) {
            zeros[i] = _hashLeftRight(zeros[i - 1], zeros[i - 1]);
        }

        // Initialize filled subtrees with zeros
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            filledSubtrees[i] = zeros[i];
        }

        // Initial root
        currentRoot = zeros[TREE_DEPTH];
        rootHistory[0] = currentRoot;
    }

    function authorizeInserter(address inserter) external onlyOwner {
        authorizedInserters[inserter] = true;
    }

    function revokeInserter(address inserter) external onlyOwner {
        authorizedInserters[inserter] = false;
    }

    function insert(bytes32 commitment) external onlyAuthorized returns (uint256 leafIndex) {
        if (nextLeafIndex >= MAX_LEAVES) revert TreeFull();

        leafIndex = nextLeafIndex;
        uint256 currentIdx = leafIndex;
        bytes32 currentHash = commitment;

        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            if (currentIdx % 2 == 0) {
                filledSubtrees[i] = currentHash;
                currentHash = _hashLeftRight(currentHash, zeros[i]);
            } else {
                currentHash = _hashLeftRight(filledSubtrees[i], currentHash);
            }
            currentIdx /= 2;
        }

        currentRoot = currentHash;
        currentRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        rootHistory[currentRootIndex] = currentRoot;

        nextLeafIndex++;

        emit CommitmentInserted(commitment, leafIndex, currentRoot);
        return leafIndex;
    }

    function getRoot() external view returns (bytes32) {
        return currentRoot;
    }

    function getHistoricalRoot(uint256 rootIndex) external view returns (bytes32) {
        return rootHistory[rootIndex % ROOT_HISTORY_SIZE];
    }

    function isKnownRoot(bytes32 root) external view returns (bool) {
        if (root == bytes32(0)) return false;

        for (uint256 i = 0; i < ROOT_HISTORY_SIZE; i++) {
            if (rootHistory[i] == root) {
                return true;
            }
        }
        return false;
    }

    function getNextLeafIndex() external view returns (uint256) {
        return nextLeafIndex;
    }

    /// @notice Get the zero value for a given tree level (SDK compatibility)
    function getZeroValue(uint256 level) external view returns (bytes32) {
        require(level <= TREE_DEPTH, "Level too high");
        return zeros[level];
    }

    function verifyProof(
        bytes32 leaf,
        bytes32[] calldata pathElements,
        uint256[] calldata pathIndices,
        bytes32 root
    ) external pure returns (bool) {
        if (pathElements.length != TREE_DEPTH || pathIndices.length != TREE_DEPTH) {
            revert InvalidProof();
        }

        bytes32 currentHash = leaf;
        for (uint256 i = 0; i < TREE_DEPTH; i++) {
            if (pathIndices[i] == 0) {
                currentHash = _hashLeftRight(currentHash, pathElements[i]);
            } else {
                currentHash = _hashLeftRight(pathElements[i], currentHash);
            }
        }

        return currentHash == root;
    }

    function _hashLeftRight(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }
}
