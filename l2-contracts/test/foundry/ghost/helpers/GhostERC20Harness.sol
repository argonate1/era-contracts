// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import {IGhostERC20, IGhostCommitmentTree, IGhostNullifierRegistry, IGhostVerifier} from "../../../../contracts/ghost/interfaces/IGhostContracts.sol";
import {GhostHash} from "../../../../contracts/ghost/libraries/GhostHash.sol";

/// @title GhostERC20Harness
/// @notice Test-only version of GhostERC20 without _disableInitializers() in constructor
/// @dev This allows direct deployment + initialization for testing purposes
contract GhostERC20Harness is ERC20PermitUpgradeable, IGhostERC20 {
    /// @notice The commitment tree for storing ghost commitments
    IGhostCommitmentTree public commitmentTree;

    /// @notice The nullifier registry for preventing double-spend
    IGhostNullifierRegistry public nullifierRegistry;

    /// @notice The ZK verifier for redemption proofs
    IGhostVerifier public verifier;

    /// @notice Address of the origin token on L1
    address public originToken;

    /// @notice The asset ID for this token
    bytes32 public assetId;

    /// @notice The native token vault that can mint/burn
    address public nativeTokenVault;

    /// @notice Token decimals
    uint8 private _decimals;

    /// @notice Total amount currently ghosted (for statistics)
    uint256 public totalGhosted;

    /// @notice Total amount redeemed (for statistics)
    uint256 public totalRedeemed;

    // Errors
    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidProof();
    error NullifierAlreadySpent();
    error UnknownMerkleRoot();
    error InsufficientRedeemAmount();
    error AmountMismatch();

    /// @notice Modifier to restrict minting/burning to the native token vault
    modifier onlyNTV() {
        if (msg.sender != nativeTokenVault) {
            revert Unauthorized();
        }
        _;
    }

    // NOTE: No _disableInitializers() call in constructor for testing!
    constructor() {}

    /// @notice Initialize the ghost token
    function initialize(
        bytes32 _assetId,
        address _originToken,
        string memory _name,
        string memory _symbol,
        uint8 _tokenDecimals,
        address _commitmentTree,
        address _nullifierRegistry,
        address _verifier
    ) external initializer {
        if (_originToken == address(0)) revert ZeroAddress();
        if (_commitmentTree == address(0)) revert ZeroAddress();
        if (_nullifierRegistry == address(0)) revert ZeroAddress();
        if (_verifier == address(0)) revert ZeroAddress();

        // Initialize ERC20 with "Ghost" prefix
        string memory ghostName = string(abi.encodePacked("Ghost ", _name));
        string memory ghostSymbol = string(abi.encodePacked("g", _symbol));

        __ERC20_init_unchained(ghostName, ghostSymbol);
        __ERC20Permit_init(ghostName);

        assetId = _assetId;
        originToken = _originToken;
        _decimals = _tokenDecimals;
        nativeTokenVault = msg.sender;

        commitmentTree = IGhostCommitmentTree(_commitmentTree);
        nullifierRegistry = IGhostNullifierRegistry(_nullifierRegistry);
        verifier = IGhostVerifier(_verifier);
    }

    /// @notice Returns the number of decimals
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint tokens (only callable by NTV during bridge deposit)
    function bridgeMint(address _to, uint256 _amount) external onlyNTV {
        _mint(_to, _amount);
    }

    /// @notice Burn tokens (only callable by NTV during bridge withdrawal)
    function bridgeBurn(address _from, uint256 _amount) external onlyNTV {
        _burn(_from, _amount);
    }

    /// @inheritdoc IGhostERC20
    function ghost(uint256 amount, bytes32 commitment) external returns (uint256 leafIndex) {
        if (amount == 0) revert ZeroAmount();

        // Burn the tokens from sender
        _burn(msg.sender, amount);

        // Insert commitment into Merkle tree
        leafIndex = commitmentTree.insert(commitment);

        // Update statistics
        totalGhosted += amount;

        emit Ghosted(msg.sender, amount, commitment, leafIndex);
    }

    /// @inheritdoc IGhostERC20
    function redeem(
        uint256 amount,
        address recipient,
        bytes32 nullifier,
        bytes32 merkleRoot,
        bytes32[] calldata merkleProof,
        uint256[] calldata pathIndices,
        bytes calldata zkProof
    ) external {
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
        publicInputs[3] = uint256(uint160(address(this)));
        publicInputs[4] = uint256(uint160(recipient));

        if (!verifier.verifyRedemptionProof(zkProof, publicInputs)) {
            revert InvalidProof();
        }

        // 4. Mark nullifier as spent
        nullifierRegistry.markSpent(nullifier);

        // 5. Mint tokens to recipient
        _mint(recipient, amount);

        // Update statistics
        totalRedeemed += amount;

        emit Redeemed(amount, recipient, nullifier);
    }

    /// @inheritdoc IGhostERC20
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
    ) external returns (uint256 newLeafIndex) {
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
        publicInputs[3] = uint256(uint160(address(this)));
        publicInputs[4] = uint256(uint160(recipient));
        publicInputs[5] = originalAmount;
        publicInputs[6] = redeemAmount;
        publicInputs[7] = uint256(newCommitment);

        if (!verifier.verifyPartialRedemptionProof(zkProof, publicInputs)) {
            revert InvalidProof();
        }

        // 4. Mark old nullifier as spent
        nullifierRegistry.markSpent(oldNullifier);

        // 5. Mint redeemed amount to recipient
        _mint(recipient, redeemAmount);

        // 6. If there's remaining balance, insert new commitment
        uint256 remainingAmount = originalAmount - redeemAmount;
        if (remainingAmount > 0) {
            newLeafIndex = commitmentTree.insert(newCommitment);
        }

        // Update statistics
        totalRedeemed += redeemAmount;

        emit PartialRedeemed(redeemAmount, recipient, oldNullifier, newCommitment, newLeafIndex);
    }

    /// @notice Get ghost statistics
    function getGhostStats() external view returns (
        uint256 ghosted,
        uint256 redeemed,
        uint256 outstanding
    ) {
        ghosted = totalGhosted;
        redeemed = totalRedeemed;
        outstanding = totalGhosted - totalRedeemed;
    }

    /// @notice Helper to compute a commitment
    function computeCommitment(
        bytes32 secret,
        bytes32 nullifier,
        uint256 amount
    ) external view returns (bytes32) {
        return GhostHash.computeCommitment(secret, nullifier, amount, address(this));
    }

    /// @notice Get the L1 origin token address
    function l1Address() external view returns (address) {
        return originToken;
    }
}
