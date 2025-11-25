// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {ERC1967Upgrade} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Upgrade.sol";

import {IGhostERC20, IGhostCommitmentTree, IGhostNullifierRegistry, IGhostVerifier} from "./interfaces/IGhostContracts.sol";

/// @title GhostERC20
/// @author Ghost Protocol Team
/// @notice Ghost-enabled ERC20 token with privacy-preserving transfers
/// @dev This token extends standard ERC20 with ghost capabilities:
///      - ghost(): Burn tokens and create a cryptographic commitment
///      - redeem(): Mint tokens to ANY address with a ZK proof (breaks the link!)
///      - redeemPartial(): Partially redeem with change going to a new commitment
///
///      Privacy model:
///      - Ghosting is PUBLIC (observers see who ghosted and how much)
///      - Redemption is UNLINKABLE (observers cannot connect redeem to ghost)
///      - The voucher (secret + nullifier) is the ONLY link, held off-chain by user
///
///      Gas costs (approximate):
///      - ghost(): ~50K gas (commitment storage + event)
///      - redeem(): ~350K gas (includes ZK verification + mint)
///      - redeemPartial(): ~400K gas (includes ZK verification + mint + new commitment)
///
/// @custom:security-contact security@ghostprotocol.xyz
///
/// @custom:security-assumptions
///      1. The ZK verifier correctly validates proofs (commitment membership + nullifier correctness)
///      2. The commitment tree is append-only and maintains valid Merkle roots
///      3. Nullifiers cannot be predicted without knowledge of the secret
///      4. The hash function (Poseidon, computed off-chain) is collision-resistant
///      5. Only the NativeTokenVault can mint/burn tokens via bridge operations
///      6. Users keep their vouchers (secret + nullifier) secure and off-chain
///
/// @custom:invariants
///      1. totalSupply() = bridgedIn - bridgedOut + ghostOutstanding (where ghostOutstanding = totalGhosted - totalRedeemed)
///      2. totalGhosted >= totalRedeemed (can never redeem more than ghosted)
///      3. Each nullifier can only be used once across all redemptions
///      4. A commitment can only be redeemed if it exists in a known Merkle root
///      5. Partial redemption: redeemAmount + remainingCommitment = originalAmount
///
/// @custom:audit-notes
///      - CRITICAL: ZK proof verification must occur BEFORE any state changes
///      - CRITICAL: Nullifier must be marked spent BEFORE minting tokens
///      - The privacy guarantee depends on the anonymity set size (more users = more privacy)
///      - Consider timing attacks: ghost and redeem in same block reduces privacy
///      - Front-running protection: Redemptions are not front-runnable due to ZK proofs
contract GhostERC20 is ERC20PermitUpgradeable, IGhostERC20, ERC1967Upgrade {
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

    /// @dev Disable initializers in implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the ghost token
    /// @param _assetId The asset ID for this token
    /// @param _originToken The L1 token address
    /// @param _name Token name (will be prefixed with "Ghost ")
    /// @param _symbol Token symbol (will be prefixed with "g")
    /// @param _tokenDecimals Token decimals
    /// @param _commitmentTree The commitment tree address
    /// @param _nullifierRegistry The nullifier registry address
    /// @param _verifier The ZK verifier address
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
    /// @param _to Recipient address
    /// @param _amount Amount to mint
    function bridgeMint(address _to, uint256 _amount) external onlyNTV {
        _mint(_to, _amount);
    }

    /// @notice Burn tokens (only callable by NTV during bridge withdrawal)
    /// @param _from Address to burn from
    /// @param _amount Amount to burn
    function bridgeBurn(address _from, uint256 _amount) external onlyNTV {
        _burn(_from, _amount);
    }

    /// @inheritdoc IGhostERC20
    /// @notice Ghost tokens - burn and create a commitment for later redemption
    /// @dev The commitment should be: hash(secret || nullifier || amount || token)
    ///      The user must store the secret and nullifier off-chain in their voucher
    ///      Commitment is computed OFF-CHAIN using Poseidon (circomlibjs)
    ///
    ///      Gas cost: ~50,000 gas (no on-chain hashing)
    ///
    ///      Flow:
    ///      1. Burn tokens from sender (reduces total supply temporarily)
    ///      2. Insert commitment into Merkle tree (creates proof of deposit)
    ///      3. Update statistics for protocol health monitoring
    ///      4. Emit event for off-chain indexing (PUBLIC - reduces privacy if not batched)
    ///
    /// @param amount The amount of tokens to ghost (must be > 0)
    /// @param commitment The hash commitment computed as hash(secret, nullifier, amount, token)
    /// @return leafIndex The Merkle tree leaf index where commitment was inserted
    ///
    /// @custom:security The commitment should be computed CLIENT-SIDE to protect the secret.
    ///                  Never pass raw secrets to on-chain functions.
    /// @custom:privacy Ghosting is PUBLIC - observers see who ghosted and the amount.
    ///                 Privacy comes from the unlinkable redemption.
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
    /// @notice Redeem ghosted tokens with a ZK proof
    /// @dev The proof demonstrates knowledge of (secret, nullifier) without revealing them
    ///      This breaks the link between ghost and redeem transactions
    ///
    ///      Gas cost: ~350,000 gas (ZK verification is the main cost)
    ///
    ///      Security flow (order is critical!):
    ///      1. Validate inputs (amount > 0, recipient != 0)
    ///      2. Check nullifier NOT spent (double-spend prevention)
    ///      3. Verify Merkle root is known (commitment exists)
    ///      4. Verify ZK proof (proves knowledge of secret without revealing)
    ///      5. Mark nullifier as spent (BEFORE minting - prevents reentrancy)
    ///      6. Mint tokens to recipient (can be ANY address)
    ///
    /// @param amount The amount to redeem (must match commitment amount)
    /// @param recipient The address to receive tokens (breaks the link!)
    /// @param nullifier The nullifier derived from user's secret
    /// @param merkleRoot A known root from the commitment tree
    /// @param merkleProof Sibling hashes proving commitment membership
    /// @param pathIndices Path directions (0=left, 1=right) in the tree
    /// @param zkProof The ZK-SNARK proof of valid redemption
    ///
    /// @custom:security Nullifier MUST be marked spent before minting.
    /// @custom:privacy The tx submitter can be different from recipient (relayer pattern).
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
    /// @notice Partially redeem ghosted tokens
    /// @dev Allows spending part of a voucher and getting "change" as a new commitment
    ///
    ///      Gas cost: ~400,000 gas (ZK verification + new commitment insertion)
    ///
    ///      This enables "change" functionality:
    ///      - User has voucher for 1000 tokens
    ///      - Redeems 300 to Bob
    ///      - Gets new voucher for remaining 700
    ///
    ///      Security flow (order is critical!):
    ///      1. Validate inputs (amounts, recipient)
    ///      2. Check redeemAmount <= originalAmount
    ///      3. Check nullifier NOT spent
    ///      4. Verify Merkle root is known
    ///      5. Verify ZK proof (proves partial redemption validity)
    ///      6. Mark OLD nullifier as spent
    ///      7. Mint redeemed amount to recipient
    ///      8. Insert NEW commitment for remaining balance
    ///
    /// @param redeemAmount The amount to redeem now
    /// @param originalAmount The original ghosted amount
    /// @param recipient The address to receive redeemed tokens
    /// @param oldNullifier The nullifier for the original commitment
    /// @param newCommitment The commitment for the remaining balance
    /// @param merkleRoot A known root from the commitment tree
    /// @param merkleProof Sibling hashes proving commitment membership
    /// @param pathIndices Path directions in the tree
    /// @param zkProof The ZK-SNARK proof of valid partial redemption
    /// @return newLeafIndex The Merkle tree index of the new commitment (0 if fully redeemed)
    ///
    /// @custom:security User must generate NEW secret/nullifier for the change commitment.
    ///                  Reusing secrets would compromise the new voucher.
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
    /// @return ghosted Total amount ghosted
    /// @return redeemed Total amount redeemed
    /// @return outstanding Amount currently ghosted but not redeemed
    function getGhostStats() external view returns (
        uint256 ghosted,
        uint256 redeemed,
        uint256 outstanding
    ) {
        ghosted = totalGhosted;
        redeemed = totalRedeemed;
        outstanding = totalGhosted - totalRedeemed;
    }

    /// @notice Get the L1 origin token address
    function l1Address() external view returns (address) {
        return originToken;
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
    /// @return "poseidon-offchain" indicating commitments are hashed off-chain with Poseidon
    function hashFunction() external pure returns (string memory) {
        return "poseidon-offchain";
    }
}
