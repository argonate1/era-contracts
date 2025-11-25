// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Create2} from "@openzeppelin/contracts-v4/utils/Create2.sol";

import {IGhostNativeTokenVault} from "./interfaces/IGhostContracts.sol";
import {GhostERC20} from "./GhostERC20.sol";
import {CommitmentTree} from "./CommitmentTree.sol";
import {NullifierRegistry} from "./NullifierRegistry.sol";
import {GhostVerifier} from "./GhostVerifier.sol";

/// @title GhostNativeTokenVault
/// @author GhostChain
/// @notice Native Token Vault that creates ghost-enabled tokens for all bridged assets
/// @dev This contract replaces the standard L2NativeTokenVault to make ALL bridged tokens
///      automatically ghost-capable. When USDC bridges from L1, users receive gUSDC which
///      has built-in ghost/redeem functionality.
///
///      Architecture (Off-Chain Tree):
///      - Receives bridgeMint calls from L2AssetRouter
///      - Deploys GhostERC20 tokens for each new asset
///      - All ghost tokens share the same CommitmentTree and NullifierRegistry
///      - This creates a larger anonymity set across all tokens
///      - Merkle tree computation happens OFF-CHAIN
///      - Authorized relayer submits roots to CommitmentTree
contract GhostNativeTokenVault is IGhostNativeTokenVault {
    /// @notice The L2 Asset Router that calls bridgeMint/bridgeBurn
    address public immutable L2_ASSET_ROUTER;

    /// @notice The L1 chain ID (for asset ID computation)
    uint256 public immutable L1_CHAIN_ID;

    /// @notice Shared commitment tree for all ghost tokens
    CommitmentTree public immutable commitmentTree;

    /// @notice Shared nullifier registry for all ghost tokens
    NullifierRegistry public immutable nullifierRegistry;

    /// @notice ZK verifier for all ghost tokens
    GhostVerifier public immutable verifier;

    /// @notice Beacon for GhostERC20 proxy pattern
    UpgradeableBeacon public immutable ghostTokenBeacon;

    /// @notice Mapping from assetId to ghost token address
    mapping(bytes32 => address) public ghostTokens;

    /// @notice Mapping from L1 token address to ghost token address
    mapping(address => address) public l1TokenToGhostToken;

    /// @notice Reverse mapping from ghost token to assetId
    mapping(address => bytes32) public ghostTokenToAssetId;

    /// @notice Owner address
    address public owner;

    // Errors
    error Unauthorized();
    error ZeroAddress();
    error TokenAlreadyDeployed();
    error TokenNotDeployed();

    // Events
    event GhostTokenDeployed(
        bytes32 indexed assetId,
        address indexed ghostToken,
        address indexed originToken,
        string name,
        string symbol
    );

    modifier onlyAssetRouter() {
        if (msg.sender != L2_ASSET_ROUTER) {
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

    // Precomputed initial root for empty tree (Z20 - must match SDK)
    bytes32 constant INITIAL_ROOT = bytes32(0x0b4a6c626bd085f652fb17cad5b70c9db903266b5a3f456ea6373a3cf97f3453);

    /// @notice Constructor
    /// @param _l2AssetRouter The L2 Asset Router address
    /// @param _l1ChainId The L1 chain ID
    /// @param _ghostTokenImplementation The GhostERC20 implementation address
    /// @param _rootSubmitter The authorized root submitter (relayer) address
    /// @param _testMode Whether to run verifier in test mode (accepts all proofs)
    constructor(
        address _l2AssetRouter,
        uint256 _l1ChainId,
        address _ghostTokenImplementation,
        address _rootSubmitter,
        bool _testMode
    ) {
        if (_l2AssetRouter == address(0)) revert ZeroAddress();
        if (_ghostTokenImplementation == address(0)) revert ZeroAddress();
        if (_rootSubmitter == address(0)) revert ZeroAddress();

        L2_ASSET_ROUTER = _l2AssetRouter;
        L1_CHAIN_ID = _l1ChainId;
        owner = msg.sender;

        // Deploy shared infrastructure with initial root (off-chain tree architecture)
        commitmentTree = new CommitmentTree(INITIAL_ROOT);
        nullifierRegistry = new NullifierRegistry();
        verifier = new GhostVerifier(_testMode);

        // Set the authorized root submitter (relayer)
        commitmentTree.setRootSubmitter(_rootSubmitter);

        // Create beacon for ghost token proxies
        ghostTokenBeacon = new UpgradeableBeacon(_ghostTokenImplementation);
    }

    /// @notice Called by L2AssetRouter when tokens are bridged from L1
    /// @param _chainId The origin chain ID
    /// @param _assetId The asset ID
    /// @param _transferData Encoded transfer data (receiver, amount, token metadata)
    function bridgeMint(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external onlyAssetRouter {
        // Decode transfer data
        (
            address receiver,
            uint256 amount,
            address originToken,
            bytes memory erc20Data
        ) = _decodeTransferData(_transferData);

        // Get or deploy ghost token
        address ghostToken = ghostTokens[_assetId];
        if (ghostToken == address(0)) {
            ghostToken = _deployGhostToken(_assetId, originToken, erc20Data);
        }

        // Mint ghost tokens to receiver
        GhostERC20(ghostToken).bridgeMint(receiver, amount);
    }

    /// @notice Called by L2AssetRouter when tokens are being withdrawn to L1
    /// @param _chainId The destination chain ID
    /// @param _assetId The asset ID
    /// @param _transferData Encoded transfer data
    function bridgeBurn(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external onlyAssetRouter {
        (address from, uint256 amount, , ) = _decodeTransferData(_transferData);

        address ghostToken = ghostTokens[_assetId];
        if (ghostToken == address(0)) revert TokenNotDeployed();

        // Burn ghost tokens
        GhostERC20(ghostToken).bridgeBurn(from, amount);
    }

    /// @notice Deploy a new ghost token for an asset
    /// @param _assetId The asset ID
    /// @param _originToken The L1 token address
    /// @param _erc20Data Encoded ERC20 metadata (name, symbol, decimals)
    function _deployGhostToken(
        bytes32 _assetId,
        address _originToken,
        bytes memory _erc20Data
    ) internal returns (address ghostToken) {
        if (ghostTokens[_assetId] != address(0)) revert TokenAlreadyDeployed();

        // Decode ERC20 metadata
        (string memory name, string memory symbol, uint8 tokenDecimals) = _decodeERC20Data(_erc20Data);

        // Compute deterministic address using CREATE2
        bytes32 salt = keccak256(abi.encode(_assetId, _originToken));

        // Deploy beacon proxy
        bytes memory proxyBytecode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(address(ghostTokenBeacon), "")
        );

        ghostToken = Create2.deploy(0, salt, proxyBytecode);

        // Initialize the ghost token
        GhostERC20(ghostToken).initialize(
            _assetId,
            _originToken,
            name,
            symbol,
            tokenDecimals,
            address(commitmentTree),
            address(nullifierRegistry),
            address(verifier)
        );

        // Authorize the ghost token to insert commitments and mark nullifiers
        commitmentTree.authorizeInserter(ghostToken);
        nullifierRegistry.authorizeMarker(ghostToken);

        // Store mappings
        ghostTokens[_assetId] = ghostToken;
        l1TokenToGhostToken[_originToken] = ghostToken;
        ghostTokenToAssetId[ghostToken] = _assetId;

        emit GhostTokenDeployed(_assetId, ghostToken, _originToken, name, symbol);
    }

    /// @notice Decode transfer data from bridge
    function _decodeTransferData(bytes calldata _data) internal pure returns (
        address receiver,
        uint256 amount,
        address originToken,
        bytes memory erc20Data
    ) {
        (receiver, amount, originToken, erc20Data) = abi.decode(_data, (address, uint256, address, bytes));
    }

    /// @notice Decode ERC20 metadata
    function _decodeERC20Data(bytes memory _data) internal pure returns (
        string memory name,
        string memory symbol,
        uint8 decimals
    ) {
        if (_data.length == 0) {
            return ("Unknown Token", "UNK", 18);
        }
        (name, symbol, decimals) = abi.decode(_data, (string, string, uint8));
    }

    /// @inheritdoc IGhostNativeTokenVault
    function getGhostToken(bytes32 assetId) external view returns (address) {
        return ghostTokens[assetId];
    }

    /// @inheritdoc IGhostNativeTokenVault
    function isGhostEnabled(bytes32 assetId) external view returns (bool) {
        return ghostTokens[assetId] != address(0);
    }

    /// @notice Get ghost token by L1 token address
    /// @param l1Token The L1 token address
    /// @return The ghost token address
    function getGhostTokenByL1Address(address l1Token) external view returns (address) {
        return l1TokenToGhostToken[l1Token];
    }

    /// @notice Compute the expected ghost token address for an asset
    /// @param _assetId The asset ID
    /// @param _originToken The L1 token address
    /// @return The expected ghost token address
    function computeGhostTokenAddress(
        bytes32 _assetId,
        address _originToken
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(_assetId, _originToken));

        bytes memory proxyBytecode = abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(address(ghostTokenBeacon), "")
        );

        return Create2.computeAddress(salt, keccak256(proxyBytecode));
    }

    /// @notice Upgrade the ghost token implementation
    /// @param newImplementation The new implementation address
    function upgradeGhostTokenImplementation(address newImplementation) external onlyOwner {
        ghostTokenBeacon.upgradeTo(newImplementation);
    }

    /// @notice Transfer ownership
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    /// @notice Get the shared infrastructure addresses
    /// @return tree The commitment tree address
    /// @return registry The nullifier registry address
    /// @return zkVerifier The verifier address
    function getGhostInfrastructure() external view returns (
        address tree,
        address registry,
        address zkVerifier
    ) {
        return (address(commitmentTree), address(nullifierRegistry), address(verifier));
    }
}
