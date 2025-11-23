// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GhostConstants
/// @notice Constants for the Ghost protocol system contracts and infrastructure
/// @dev These addresses are used for deploying ghost infrastructure on L2

/// @dev System contract offset (same as in main Constants.sol)
uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000;

/// @dev User contracts offset (same as in main Constants.sol)
uint160 constant USER_CONTRACTS_OFFSET = 0xffff + 1; // 0x10000

// =============================================================================
// GHOST SYSTEM CONTRACTS (kernel space 0x8000-0xFFFF)
// =============================================================================

/// @dev GhostETH system contract - for ghosting native ETH
/// @dev Address: 0x8016 (next available after EVM_HASHES_STORAGE at 0x8015)
address constant GHOST_ETH_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x16);

// =============================================================================
// GHOST USER CONTRACTS (user space 0x10000+)
// =============================================================================

/// @dev Ghost Native Token Vault - replaces L2NativeTokenVault for ghost tokens
/// @dev Deployed in user space as it's not a system contract
address constant GHOST_NATIVE_TOKEN_VAULT = address(USER_CONTRACTS_OFFSET + 0x10);

/// @dev Shared Commitment Tree for all ghost tokens (larger anonymity set)
address constant GHOST_COMMITMENT_TREE = address(USER_CONTRACTS_OFFSET + 0x11);

/// @dev Shared Nullifier Registry for all ghost tokens
address constant GHOST_NULLIFIER_REGISTRY = address(USER_CONTRACTS_OFFSET + 0x12);

/// @dev ZK Verifier for ghost proofs
address constant GHOST_VERIFIER = address(USER_CONTRACTS_OFFSET + 0x13);

/// @dev GhostERC20 beacon for upgradeable ghost tokens
address constant GHOST_ERC20_BEACON = address(USER_CONTRACTS_OFFSET + 0x14);

// =============================================================================
// GHOST PROTOCOL CONSTANTS
// =============================================================================

/// @dev Depth of the commitment Merkle tree (2^20 = ~1M commitments)
uint256 constant GHOST_TREE_DEPTH = 20;

/// @dev Maximum number of commitments in the tree
uint256 constant GHOST_MAX_COMMITMENTS = 2 ** GHOST_TREE_DEPTH;

/// @dev Number of historical roots to keep for proof verification
uint256 constant GHOST_ROOT_HISTORY_SIZE = 100;

/// @dev Domain separator for ghost commitments
bytes32 constant GHOST_COMMITMENT_DOMAIN = keccak256("GHOST_COMMITMENT_V1");

/// @dev Domain separator for ghost nullifiers
bytes32 constant GHOST_NULLIFIER_DOMAIN = keccak256("GHOST_NULLIFIER_V1");

// =============================================================================
// GHOST TOKEN PREFIXES
// =============================================================================

/// @dev Prefix for ghost token names (e.g., "Ghost USDC")
string constant GHOST_TOKEN_NAME_PREFIX = "Ghost ";

/// @dev Prefix for ghost token symbols (e.g., "gUSDC")
string constant GHOST_TOKEN_SYMBOL_PREFIX = "g";

// =============================================================================
// ETH REPRESENTATION
// =============================================================================

/// @dev Address used to represent native ETH in commitments
/// @dev Using address(0) as the canonical ETH identifier
address constant ETH_TOKEN_ADDRESS = address(0);

/// @dev Asset ID for native ETH (computed as keccak256(chainId, NTV, address(0)))
/// @dev This is chain-specific and computed at runtime
// bytes32 constant ETH_ASSET_ID = computed at deployment time
