// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGhostContracts
/// @author Ghost Protocol Team
/// @notice Interface definitions for the Ghost Protocol privacy system
/// @dev This file contains all interfaces for the Ghost Protocol:
///      - IGhostCommitmentTree: Merkle tree for commitment storage
///      - IGhostNullifierRegistry: Double-spend prevention
///      - IGhostVerifier: ZK proof verification
///      - IGhostERC20: Ghost-enabled tokens
///      - IGhostNativeTokenVault: Bridge integration
///
/// @custom:security-contact security@ghostprotocol.xyz

/// @title IGhostCommitmentTree
/// @notice Interface for the commitment tree that stores ghost voucher commitments
/// @dev Merkle tree is computed OFF-CHAIN. Contract stores commitments and roots.
///      - Commitments are stored in an append-only array (canonical source)
///      - Roots are computed off-chain by relayer and submitted to contract
///      - Proofs are verified in ZK circuits, not on-chain
interface IGhostCommitmentTree {
    /// @notice Emitted when a new commitment is inserted
    /// @dev Note: newRoot may be bytes32(0) when tree is computed off-chain
    event CommitmentInserted(bytes32 indexed commitment, uint256 indexed leafIndex, bytes32 newRoot);

    /// @notice Insert a commitment into the tree
    /// @param commitment The commitment to insert
    /// @return leafIndex The index of the inserted leaf
    function insert(bytes32 commitment) external returns (uint256 leafIndex);

    /// @notice Get the current Merkle root
    /// @return The current root of the commitment tree
    function getRoot() external view returns (bytes32);

    /// @notice Get a historical root by index
    /// @param rootIndex The index of the historical root
    /// @return The historical root at that index
    function getHistoricalRoot(uint256 rootIndex) external view returns (bytes32);

    /// @notice Check if a root is valid (current or historical)
    /// @param root The root to check
    /// @return True if the root is valid
    function isKnownRoot(bytes32 root) external view returns (bool);

    /// @notice Get the number of inserted leaves
    /// @return The total number of commitments
    function getNextLeafIndex() external view returns (uint256);

    /// @notice Verify a Merkle proof - NOT SUPPORTED IN OFF-CHAIN ARCHITECTURE
    /// @dev Proof verification happens in ZK circuits, not on-chain.
    ///      This function exists for interface compatibility but reverts.
    /// @param leaf The leaf value (unused)
    /// @param pathElements The sibling hashes along the path (unused)
    /// @param pathIndices The path direction indicators (unused)
    /// @param root The root to verify against (unused)
    /// @return Always reverts - proofs are verified in ZK circuits
    function verifyProof(
        bytes32 leaf,
        bytes32[] calldata pathElements,
        uint256[] calldata pathIndices,
        bytes32 root
    ) external pure returns (bool);
}

/// @title IGhostNullifierRegistry
/// @notice Interface for tracking spent nullifiers to prevent double-redemption
/// @dev A nullifier is derived from the user's secret and cannot be predicted.
///      Once spent, the corresponding commitment can never be redeemed again.
interface IGhostNullifierRegistry {
    /// @notice Emitted when a nullifier is marked as spent
    event NullifierSpent(bytes32 indexed nullifier);

    /// @notice Check if a nullifier has been spent
    /// @param nullifier The nullifier to check
    /// @return True if the nullifier has been spent
    function isSpent(bytes32 nullifier) external view returns (bool);

    /// @notice Mark a nullifier as spent
    /// @param nullifier The nullifier to mark
    /// @dev Only callable by authorized ghost contracts
    function markSpent(bytes32 nullifier) external;
}

/// @title IGhostVerifier
/// @notice Interface for ZK proof verification
/// @dev Verifies ZK-SNARK proofs that prove knowledge of commitment secrets
///      without revealing the secret or which commitment is being redeemed.
interface IGhostVerifier {
    /// @notice Verify a ghost redemption proof
    /// @param proof The ZK proof data
    /// @param publicInputs The public inputs to the circuit
    /// @return True if the proof is valid
    function verifyRedemptionProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool);

    /// @notice Verify a partial redemption proof
    /// @param proof The ZK proof data
    /// @param publicInputs The public inputs including original amount, redeem amount, and new commitment
    /// @return True if the proof is valid
    function verifyPartialRedemptionProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool);
}

/// @title IGhostERC20
/// @notice Interface for ghost-enabled ERC20 tokens
/// @dev Extends standard ERC20 with ghost/redeem functionality for privacy.
///      Privacy model: ghost is public, redemption is unlinkable.
interface IGhostERC20 {
    /// @notice Emitted when tokens are ghosted
    event Ghosted(
        address indexed from,
        uint256 amount,
        bytes32 indexed commitment,
        uint256 leafIndex
    );

    /// @notice Emitted when tokens are redeemed
    event Redeemed(
        uint256 amount,
        address indexed recipient,
        bytes32 indexed nullifier
    );

    /// @notice Emitted when tokens are partially redeemed
    event PartialRedeemed(
        uint256 redeemAmount,
        address indexed recipient,
        bytes32 indexed oldNullifier,
        bytes32 indexed newCommitment,
        uint256 newLeafIndex
    );

    /// @notice Ghost tokens by burning and creating a commitment
    /// @param amount The amount of tokens to ghost
    /// @param commitment The hash commitment (hash(secret, nullifier, amount, token))
    /// @return leafIndex The index of the commitment in the Merkle tree
    function ghost(uint256 amount, bytes32 commitment) external returns (uint256 leafIndex);

    /// @notice Redeem ghosted tokens with a ZK proof
    /// @param amount The amount to redeem
    /// @param recipient The address to receive the tokens
    /// @param nullifier The nullifier for this redemption
    /// @param merkleRoot The Merkle root to verify against
    /// @param merkleProof The Merkle proof path elements
    /// @param pathIndices The Merkle proof path directions
    /// @param zkProof The ZK proof of knowledge
    function redeem(
        uint256 amount,
        address recipient,
        bytes32 nullifier,
        bytes32 merkleRoot,
        bytes32[] calldata merkleProof,
        uint256[] calldata pathIndices,
        bytes calldata zkProof
    ) external;

    /// @notice Partially redeem ghosted tokens, creating a new commitment for the remainder
    /// @param redeemAmount The amount to redeem now
    /// @param originalAmount The original ghosted amount
    /// @param recipient The address to receive the redeemed tokens
    /// @param oldNullifier The nullifier for the old commitment
    /// @param newCommitment The new commitment for the remaining balance
    /// @param merkleRoot The Merkle root to verify against
    /// @param merkleProof The Merkle proof path elements
    /// @param pathIndices The Merkle proof path directions
    /// @param zkProof The ZK proof of partial redemption validity
    /// @return newLeafIndex The index of the new commitment (0 if fully redeemed)
    function redeemPartial(
        uint256 redeemAmount,
        uint256 originalAmount,
        address recipient,
        bytes32 oldNullifier,
        bytes32 newCommitment,
        bytes32 merkleRoot,
        bytes32[] calldata merkleProof,
        uint256[] calldata pathIndices,
        bytes calldata zkProof
    ) external returns (uint256 newLeafIndex);
}

/// @title IGhostNativeTokenVault
/// @notice Interface for the ghost-enabled native token vault
/// @dev Manages deployment and tracking of ghost tokens for bridged assets.
///      Each bridged asset gets a corresponding ghost token with privacy features.
interface IGhostNativeTokenVault {
    /// @notice Emitted when a ghost token is deployed for an asset
    event GhostTokenDeployed(bytes32 indexed assetId, address indexed ghostToken, address originToken);

    /// @notice Get the ghost token address for an asset
    /// @param assetId The asset ID
    /// @return The ghost token address
    function getGhostToken(bytes32 assetId) external view returns (address);

    /// @notice Check if an asset has ghost capabilities enabled
    /// @param assetId The asset ID
    /// @return True if ghost is enabled for this asset
    function isGhostEnabled(bytes32 assetId) external view returns (bool);
}
