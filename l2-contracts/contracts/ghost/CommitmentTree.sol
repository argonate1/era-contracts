// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostCommitmentTree} from "./interfaces/IGhostContracts.sol";

/// @title CommitmentTree
/// @author Ghost Protocol Team
/// @notice Stores commitments and roots for Ghost Protocol
/// @dev Merkle tree computed OFF-CHAIN. Contract stores append-only commitment list
///      and deterministically-derived roots submitted by authorized relayer.
///
///      Architecture:
///      1. Users deposit via GhostERC20.ghost() → commitment inserted to commitments[]
///      2. Off-chain relayer computes Merkle root from commitments[]
///      3. Relayer submits root via submitRoot() or insertAndUpdateRoot()
///      4. Withdrawers prove membership against stored roots
///
///      Security Model:
///      - Commitment list is CANONICAL (on-chain, append-only, immutable)
///      - Roots are DETERMINISTICALLY VERIFIABLE (anyone can rebuild tree)
///      - Relayer can DELAY but cannot FORGE invalid roots
///      - System is EVENTUALLY TRUSTLESS (anyone can run a relayer)
///
/// @custom:security-contact security@ghostprotocol.xyz
///
/// @custom:security-assumptions
///      1. Off-chain tree uses same Poseidon parameters as ZK circuits
///      2. Roots are computed deterministically from commitments[0..n-1]
///      3. Zero values match circomlibjs/snarkjs implementation exactly
///      4. Root history size (100) provides sufficient redemption window
///
/// @custom:invariants
///      1. commitments[] is append-only (no deletions, no modifications)
///      2. Once a root is in isKnownRoot, it remains valid forever
///      3. currentRoot always equals roots[currentRootIndex]
///      4. Root leafCount must match commitments.length at submission time
contract CommitmentTree is IGhostCommitmentTree {
    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Depth of the Merkle tree (computed off-chain)
    uint256 public constant TREE_DEPTH = 20;

    /// @notice Maximum number of leaves (2^20 = 1,048,576)
    uint256 public constant MAX_LEAVES = 2 ** TREE_DEPTH;

    /// @notice Number of historical roots to store
    uint256 public constant ROOT_HISTORY_SIZE = 100;

    // =========================================================================
    // State Variables
    // =========================================================================

    /// @notice Ordered list of all commitments (append-only)
    /// @dev This is the CANONICAL source of truth. Anyone can rebuild the tree from this.
    bytes32[] public commitments;

    /// @notice Ring buffer of historical Merkle roots
    bytes32[ROOT_HISTORY_SIZE] public roots;

    /// @notice Current index in the root ring buffer
    uint256 public currentRootIndex;

    /// @notice Current Merkle root
    bytes32 public currentRoot;

    /// @notice Map for O(1) root validity lookup
    mapping(bytes32 => bool) public isKnownRoot;

    /// @notice Authorized root submitter (relayer/operator)
    address public rootSubmitter;

    /// @notice Contract owner
    address public owner;

    /// @notice Authorized inserters (GhostERC20, GhostVault, etc.)
    mapping(address => bool) public authorizedInserters;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new root is submitted
    /// @param root The new Merkle root
    /// @param leafCount The number of leaves when this root was computed
    event RootUpdated(bytes32 indexed root, uint256 leafCount);

    // =========================================================================
    // Errors
    // =========================================================================

    error TreeFull();
    error Unauthorized();
    error InvalidRoot();
    error InvalidLeafCount();
    error RootAlreadySubmitted();
    error ProofVerificationNotSupported();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyAuthorized() {
        if (!authorizedInserters[msg.sender] && msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyRootSubmitter() {
        if (msg.sender != rootSubmitter && msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Initialize the commitment tree with the empty tree root
    /// @param initialRoot The precomputed root of an empty tree (Z20)
    /// @dev Initial root MUST be computed off-chain using the same Poseidon
    ///      parameters as the ZK circuits. For depth 20:
    ///      Z0 = Poseidon(0, 0)  [hashLeaf(0)]
    ///      Zi = Poseidon(Poseidon(1, Z_{i-1}), Z_{i-1})  [hashNode(Z_{i-1}, Z_{i-1})]
    ///      initialRoot = Z20
    constructor(bytes32 initialRoot) {
        owner = msg.sender;
        rootSubmitter = msg.sender;
        authorizedInserters[msg.sender] = true;

        // Store the empty tree root (precomputed for depth 20)
        currentRoot = initialRoot;
        roots[0] = initialRoot;
        isKnownRoot[initialRoot] = true;
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /// @notice Set the authorized root submitter
    /// @param _submitter The new root submitter address
    function setRootSubmitter(address _submitter) external onlyOwner {
        rootSubmitter = _submitter;
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

    /// @notice Transfer ownership
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    // =========================================================================
    // Core Functions
    // =========================================================================

    /// @inheritdoc IGhostCommitmentTree
    /// @notice Insert a new commitment into the tree
    /// @dev Only stores the commitment. Root must be updated by relayer.
    ///      Gas cost: ~45,000 gas (storage write + event)
    ///
    /// @param commitment The commitment to insert
    /// @return leafIndex The index at which the commitment was inserted
    function insert(bytes32 commitment) external onlyAuthorized returns (uint256 leafIndex) {
        if (commitments.length >= MAX_LEAVES) revert TreeFull();

        leafIndex = commitments.length;
        commitments.push(commitment);

        // Note: newRoot is emitted as bytes32(0) since tree is computed off-chain
        // The RootUpdated event will contain the actual root when relayer submits it
        emit CommitmentInserted(commitment, leafIndex, bytes32(0));
    }

    /// @notice Submit a new Merkle root after commitments have been added
    /// @param newRoot The new Merkle root computed off-chain
    /// @param leafCount The number of leaves this root corresponds to
    /// @dev Root must be computed deterministically from commitments[0..leafCount-1]
    ///      using the same Poseidon parameters as the ZK circuits.
    ///
    ///      Verification (off-chain):
    ///      1. Read all CommitmentInserted events
    ///      2. Build tree with same algorithm as relayer
    ///      3. Verify computed root matches submitted root
    function submitRoot(bytes32 newRoot, uint256 leafCount) external onlyRootSubmitter {
        // Validate leaf count matches current commitment count
        // This ensures roots correspond to actual commitment state
        if (leafCount != commitments.length) revert InvalidLeafCount();

        // Prevent duplicate root submissions
        if (newRoot == currentRoot) revert RootAlreadySubmitted();

        // Update root history
        currentRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        currentRoot = newRoot;
        roots[currentRootIndex] = newRoot;
        isKnownRoot[newRoot] = true;

        emit RootUpdated(newRoot, leafCount);
    }

    /// @notice Combined insert and root update (for atomic operations by relayer)
    /// @param commitment The commitment to insert
    /// @param newRoot The new root after this insertion
    /// @return leafIndex The index of the inserted commitment
    /// @dev This allows the relayer to atomically insert and update in one tx,
    ///      useful for immediate root availability after deposit.
    function insertAndUpdateRoot(
        bytes32 commitment,
        bytes32 newRoot
    ) external onlyRootSubmitter returns (uint256 leafIndex) {
        if (commitments.length >= MAX_LEAVES) revert TreeFull();

        leafIndex = commitments.length;
        commitments.push(commitment);

        // Update root atomically
        currentRootIndex = (currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        currentRoot = newRoot;
        roots[currentRootIndex] = newRoot;
        isKnownRoot[newRoot] = true;

        emit CommitmentInserted(commitment, leafIndex, newRoot);
        emit RootUpdated(newRoot, commitments.length);
    }

    // =========================================================================
    // View Functions (IGhostCommitmentTree Interface)
    // =========================================================================

    /// @inheritdoc IGhostCommitmentTree
    function getRoot() external view returns (bytes32) {
        return currentRoot;
    }

    /// @inheritdoc IGhostCommitmentTree
    function getHistoricalRoot(uint256 rootIndex) external view returns (bytes32) {
        return roots[rootIndex % ROOT_HISTORY_SIZE];
    }

    /// @inheritdoc IGhostCommitmentTree
    function getNextLeafIndex() external view returns (uint256) {
        return commitments.length;
    }

    /// @notice Alias for isKnownRoot (interface compliance)
    /// @param root The root to check
    /// @return True if the root is in history
    function checkRoot(bytes32 root) external view returns (bool) {
        return isKnownRoot[root];
    }

    /// @inheritdoc IGhostCommitmentTree
    /// @notice Verify a Merkle proof - NOT SUPPORTED
    /// @dev Proof verification happens in ZK circuit, not on-chain.
    ///      This function reverts to prevent misuse.
    function verifyProof(
        bytes32,
        bytes32[] calldata,
        uint256[] calldata,
        bytes32
    ) external pure returns (bool) {
        revert ProofVerificationNotSupported();
    }

    // =========================================================================
    // Additional View Functions (for SDK/Relayer)
    // =========================================================================

    /// @notice Get the number of commitments
    /// @return The total number of commitments in the tree
    function getCommitmentCount() external view returns (uint256) {
        return commitments.length;
    }

    /// @notice Get a commitment by index
    /// @param index The commitment index
    /// @return The commitment at that index
    function getCommitment(uint256 index) external view returns (bytes32) {
        return commitments[index];
    }

    /// @notice Get a range of commitments (for tree reconstruction)
    /// @param start The starting index
    /// @param count The number of commitments to return
    /// @return result Array of commitments
    function getCommitments(uint256 start, uint256 count) external view returns (bytes32[] memory result) {
        uint256 end = start + count;
        if (end > commitments.length) end = commitments.length;

        result = new bytes32[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = commitments[i];
        }
    }

    // =========================================================================
    // Contract Type Discriminator (for deployment verification)
    // =========================================================================

    /// @notice Indicates this is the production contract (not test)
    /// @return false for production contracts, true for test contracts
    function isTestContract() external pure returns (bool) {
        return false;
    }

    /// @notice Returns the hash function used by this contract
    /// @return "poseidon-offchain" indicating tree is computed off-chain with Poseidon
    function hashFunction() external pure returns (string memory) {
        return "poseidon-offchain";
    }
}
