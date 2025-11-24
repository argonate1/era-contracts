// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostERC20, IGhostCommitmentTree, IGhostNullifierRegistry, IGhostVerifier} from "../interfaces/IGhostContracts.sol";

/// @title TestGhostERC20
/// @notice Simplified Ghost-enabled ERC20 for ZKsync deployment testing
contract TestGhostERC20 is IGhostERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    // Ghost stats tracking
    uint256 public totalGhosted;
    uint256 public totalRedeemed;

    bytes32 public assetId;
    address public originToken;

    IGhostCommitmentTree public commitmentTree;
    IGhostNullifierRegistry public nullifierRegistry;
    IGhostVerifier public verifier;

    address public owner;
    bool public initialized;

    error AlreadyInitialized();
    error Unauthorized();
    error InvalidRoot();
    error NullifierAlreadySpent();
    error InsufficientBalance();
    error InvalidProof();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function initialize(
        bytes32 _assetId,
        address _originToken,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _commitmentTree,
        address _nullifierRegistry,
        address _verifier
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        assetId = _assetId;
        originToken = _originToken;
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        commitmentTree = IGhostCommitmentTree(_commitmentTree);
        nullifierRegistry = IGhostNullifierRegistry(_nullifierRegistry);
        verifier = IGhostVerifier(_verifier);
    }

    /// @notice Mint tokens (for bridge integration)
    function bridgeMint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burn tokens (for bridge integration)
    function bridgeBurn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /// @inheritdoc IGhostERC20
    function ghost(uint256 amount, bytes32 commitment) external returns (uint256 leafIndex) {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();

        _burn(msg.sender, amount);
        leafIndex = commitmentTree.insert(commitment);
        totalGhosted += amount;

        emit Ghosted(msg.sender, amount, commitment, leafIndex);
        return leafIndex;
    }

    /// @notice Get ghost statistics (SDK compatibility)
    function getGhostStats() external view returns (uint256 ghosted, uint256 redeemed, uint256 outstanding) {
        return (totalGhosted, totalRedeemed, totalGhosted - totalRedeemed);
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
        // Verify root is valid
        if (!commitmentTree.isKnownRoot(merkleRoot)) revert InvalidRoot();

        // Check nullifier not spent
        if (nullifierRegistry.isSpent(nullifier)) revert NullifierAlreadySpent();

        // Verify ZK proof
        uint256[] memory publicInputs = new uint256[](5);
        publicInputs[0] = uint256(merkleRoot);
        publicInputs[1] = uint256(nullifier);
        publicInputs[2] = amount;
        publicInputs[3] = uint256(uint160(address(this)));
        publicInputs[4] = uint256(uint160(recipient));

        if (!verifier.verifyRedemptionProof(zkProof, publicInputs)) revert InvalidProof();

        // Mark nullifier as spent
        nullifierRegistry.markSpent(nullifier);

        // Mint tokens to recipient
        _mint(recipient, amount);
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
        // Verify root is valid
        if (!commitmentTree.isKnownRoot(merkleRoot)) revert InvalidRoot();

        // Check nullifier not spent
        if (nullifierRegistry.isSpent(oldNullifier)) revert NullifierAlreadySpent();

        // Verify ZK proof
        uint256[] memory publicInputs = new uint256[](10);
        publicInputs[0] = uint256(merkleRoot);
        publicInputs[1] = uint256(oldNullifier);
        publicInputs[2] = redeemAmount;
        publicInputs[3] = originalAmount;
        publicInputs[4] = uint256(newCommitment);
        publicInputs[5] = uint256(uint160(address(this)));
        publicInputs[6] = uint256(uint160(recipient));

        if (!verifier.verifyPartialRedemptionProof(zkProof, publicInputs)) revert InvalidProof();

        // Mark old nullifier as spent
        nullifierRegistry.markSpent(oldNullifier);

        // Insert new commitment if not fully redeemed
        if (newCommitment != bytes32(0)) {
            newLeafIndex = commitmentTree.insert(newCommitment);
        }

        // Mint redeemed amount to recipient
        _mint(recipient, redeemAmount);
        totalRedeemed += redeemAmount;

        emit PartialRedeemed(redeemAmount, recipient, oldNullifier, newCommitment, newLeafIndex);
        return newLeafIndex;
    }

    // ERC20 standard functions
    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        if (allowance[from][msg.sender] < amount) revert InsufficientBalance();

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}
