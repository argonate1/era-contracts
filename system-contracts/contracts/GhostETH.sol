// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBaseToken} from "./interfaces/IBaseToken.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {BOOTLOADER_FORMAL_ADDRESS, BASE_TOKEN_SYSTEM_CONTRACT} from "./Constants.sol";

/// @title IGhostETH
/// @notice Interface for the GhostETH system contract
interface IGhostETH {
    event Ghosted(address indexed from, uint256 amount, bytes32 indexed commitment, uint256 leafIndex);
    event Redeemed(uint256 amount, address indexed recipient, bytes32 indexed nullifier);
    event PartialRedeemed(uint256 redeemAmount, address indexed recipient, bytes32 indexed oldNullifier, bytes32 indexed newCommitment, uint256 newLeafIndex);

    function ghost(bytes32 commitment) external payable returns (uint256 leafIndex);
    function redeem(uint256 amount, address recipient, bytes32 nullifier, bytes32 merkleRoot, bytes32[] calldata merkleProof, uint256[] calldata pathIndices, bytes calldata zkProof) external;
    function redeemPartial(uint256 redeemAmount, uint256 originalAmount, address recipient, bytes32 oldNullifier, bytes32 newCommitment, bytes32 merkleRoot, bytes32[] calldata merkleProof, uint256[] calldata pathIndices, bytes calldata zkProof) external returns (uint256 newLeafIndex);
}

/// @title IGhostCommitmentTree
interface IGhostCommitmentTree {
    function insert(bytes32 commitment) external returns (uint256 leafIndex);
    function isKnownRoot(bytes32 root) external view returns (bool);
}

/// @title IGhostNullifierRegistry
interface IGhostNullifierRegistry {
    function isSpent(bytes32 nullifier) external view returns (bool);
    function markSpent(bytes32 nullifier) external;
}

/// @title IGhostVerifier
interface IGhostVerifier {
    function verifyRedemptionProof(bytes calldata proof, uint256[] calldata publicInputs) external view returns (bool);
    function verifyPartialRedemptionProof(bytes calldata proof, uint256[] calldata publicInputs) external view returns (bool);
}

/// @title GhostETH
/// @author GhostChain
/// @notice System contract for ghosting native ETH
/// @dev This is a SYSTEM CONTRACT deployed at a kernel address (0x8016)
///      It allows users to ghost native ETH with the same privacy guarantees as GhostERC20
///
///      Flow:
///      1. User calls ghost{value: amount}(commitment) - ETH is burned via L2BaseToken
///      2. Commitment is added to shared Merkle tree
///      3. Later, user (or anyone) calls redeem() with ZK proof - ETH is minted to recipient
///
///      The link between ghost and redeem is broken - observers cannot correlate them
contract GhostETH is IGhostETH, SystemContractBase {
    /// @notice The commitment tree (shared with GhostERC20 tokens for larger anonymity set)
    IGhostCommitmentTree public commitmentTree;

    /// @notice The nullifier registry (shared)
    IGhostNullifierRegistry public nullifierRegistry;

    /// @notice The ZK verifier (shared)
    IGhostVerifier public verifier;

    /// @notice Total ETH currently ghosted (for statistics)
    uint256 public totalGhosted;

    /// @notice Total ETH redeemed (for statistics)
    uint256 public totalRedeemed;

    /// @notice Whether the contract has been initialized
    bool public initialized;

    /// @notice Owner for initialization
    address public owner;

    // Errors
    error AlreadyInitialized();
    error NotInitialized();
    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidProof();
    error NullifierAlreadySpent();
    error UnknownMerkleRoot();
    error InsufficientRedeemAmount();
    error MintFailed();

    modifier onlyInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    /// @notice Initialize the GhostETH contract
    /// @dev Can only be called once, typically during system contract deployment
    /// @param _commitmentTree The shared commitment tree address
    /// @param _nullifierRegistry The shared nullifier registry address
    /// @param _verifier The ZK verifier address
    function initialize(
        address _commitmentTree,
        address _nullifierRegistry,
        address _verifier
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (_commitmentTree == address(0)) revert ZeroAddress();
        if (_nullifierRegistry == address(0)) revert ZeroAddress();
        if (_verifier == address(0)) revert ZeroAddress();

        commitmentTree = IGhostCommitmentTree(_commitmentTree);
        nullifierRegistry = IGhostNullifierRegistry(_nullifierRegistry);
        verifier = IGhostVerifier(_verifier);
        owner = msg.sender;
        initialized = true;
    }

    /// @inheritdoc IGhostETH
    /// @notice Ghost ETH by burning and creating a commitment
    /// @param commitment The hash commitment (hash(secret, nullifier, amount, ETH_ADDRESS))
    /// @return leafIndex The index of the commitment in the Merkle tree
    function ghost(bytes32 commitment) external payable onlyInitialized returns (uint256 leafIndex) {
        if (msg.value == 0) revert ZeroAmount();

        // The ETH sent with this call is automatically deducted from sender's balance
        // We need to "burn" it by sending to address(0) or keeping it locked here
        // Since this is a system contract, we'll keep it locked (the contract holds the ETH)

        // Insert commitment into Merkle tree
        leafIndex = commitmentTree.insert(commitment);

        // Update statistics
        totalGhosted += msg.value;

        emit Ghosted(msg.sender, msg.value, commitment, leafIndex);
    }

    /// @inheritdoc IGhostETH
    /// @notice Redeem ghosted ETH with a ZK proof
    function redeem(
        uint256 amount,
        address recipient,
        bytes32 nullifier,
        bytes32 merkleRoot,
        bytes32[] calldata merkleProof,
        uint256[] calldata pathIndices,
        bytes calldata zkProof
    ) external onlyInitialized {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        // 1. Check nullifier hasn't been spent
        if (nullifierRegistry.isSpent(nullifier)) {
            revert NullifierAlreadySpent();
        }

        // 2. Verify the Merkle root is known
        if (!commitmentTree.isKnownRoot(merkleRoot)) {
            revert UnknownMerkleRoot();
        }

        // 3. Verify the ZK proof
        uint256[] memory publicInputs = new uint256[](5);
        publicInputs[0] = uint256(merkleRoot);
        publicInputs[1] = uint256(nullifier);
        publicInputs[2] = amount;
        publicInputs[3] = uint256(uint160(address(0))); // ETH represented as address(0)
        publicInputs[4] = uint256(uint160(recipient));

        if (!verifier.verifyRedemptionProof(zkProof, publicInputs)) {
            revert InvalidProof();
        }

        // 4. Mark nullifier as spent
        nullifierRegistry.markSpent(nullifier);

        // 5. Transfer ETH to recipient from this contract's balance
        // The ETH was locked here during ghost()
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert MintFailed();

        // Update statistics
        totalRedeemed += amount;

        emit Redeemed(amount, recipient, nullifier);
    }

    /// @inheritdoc IGhostETH
    /// @notice Partially redeem ghosted ETH
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
    ) external onlyInitialized returns (uint256 newLeafIndex) {
        if (redeemAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (redeemAmount > originalAmount) revert InsufficientRedeemAmount();

        // 1. Check nullifier hasn't been spent
        if (nullifierRegistry.isSpent(oldNullifier)) {
            revert NullifierAlreadySpent();
        }

        // 2. Verify the Merkle root is known
        if (!commitmentTree.isKnownRoot(merkleRoot)) {
            revert UnknownMerkleRoot();
        }

        // 3. Verify the ZK proof for partial redemption
        uint256[] memory publicInputs = new uint256[](8);
        publicInputs[0] = uint256(merkleRoot);
        publicInputs[1] = uint256(oldNullifier);
        publicInputs[2] = redeemAmount;
        publicInputs[3] = uint256(uint160(address(0))); // ETH
        publicInputs[4] = uint256(uint160(recipient));
        publicInputs[5] = originalAmount;
        publicInputs[6] = redeemAmount;
        publicInputs[7] = uint256(newCommitment);

        if (!verifier.verifyPartialRedemptionProof(zkProof, publicInputs)) {
            revert InvalidProof();
        }

        // 4. Mark old nullifier as spent
        nullifierRegistry.markSpent(oldNullifier);

        // 5. Transfer redeemed ETH to recipient
        (bool success, ) = recipient.call{value: redeemAmount}("");
        if (!success) revert MintFailed();

        // 6. If there's remaining balance, insert new commitment
        uint256 remainingAmount = originalAmount - redeemAmount;
        if (remainingAmount > 0) {
            newLeafIndex = commitmentTree.insert(newCommitment);
        }

        // Update statistics
        totalRedeemed += redeemAmount;

        emit PartialRedeemed(redeemAmount, recipient, oldNullifier, newCommitment, newLeafIndex);
    }

    /// @notice Get ghost statistics for ETH
    /// @return ghosted Total ETH ghosted
    /// @return redeemed Total ETH redeemed
    /// @return outstanding ETH currently ghosted but not redeemed
    function getGhostStats() external view returns (
        uint256 ghosted,
        uint256 redeemed,
        uint256 outstanding
    ) {
        ghosted = totalGhosted;
        redeemed = totalRedeemed;
        outstanding = totalGhosted - totalRedeemed;
    }

    /// @notice Get the contract's ETH balance (should equal outstanding ghosted ETH)
    function getLockedETH() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Receive ETH (only from ghost function or system)
    receive() external payable {}
}
