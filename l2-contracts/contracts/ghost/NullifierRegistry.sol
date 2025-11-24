// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostNullifierRegistry} from "./interfaces/IGhostContracts.sol";

/// @title NullifierRegistry
/// @author Ghost Protocol Team
/// @notice Tracks spent nullifiers to prevent double-redemption of ghost vouchers
/// @dev A nullifier is a unique value derived from the user's secret and commitment.
///      Once a nullifier is spent, the corresponding commitment cannot be redeemed again.
///      This enables unlinkable redemptions - observers cannot connect ghost to redeem.
///
///      Design rationale:
///      - Single mapping for O(1) spent checks (~2600 gas for SLOAD)
///      - No nullifier-to-commitment mapping (preserves privacy)
///      - Authorized marker pattern allows multiple ghost token contracts
///
/// @custom:security-contact security@ghostprotocol.xyz
///
/// @custom:security-assumptions
///      1. Nullifiers are unpredictable without knowledge of the secret
///      2. The nullifier derivation function is collision-resistant
///      3. Only authorized GhostERC20 contracts can mark nullifiers
///      4. A nullifier can only be derived from a valid (secret, commitment) pair
///      5. The ZK circuit guarantees nullifier correctness before reaching this contract
///
/// @custom:invariants
///      1. Once spent[nullifier] = true, it can never become false
///      2. totalSpent monotonically increases and equals count of true values in spent
///      3. A nullifier can only be marked spent once (prevents re-entrance attacks)
///      4. Zero nullifier (bytes32(0)) can never be marked as spent
///      5. Only authorizedMarkers or owner can call markSpent
///
/// @custom:audit-notes
///      - CRITICAL: Double-spend prevention is the core security guarantee
///      - The spent mapping must be checked BEFORE any token minting
///      - No storage of nullifier-to-amount mapping (privacy requirement)
///      - Consider gas costs for batch operations in high-volume scenarios
contract NullifierRegistry is IGhostNullifierRegistry {
    /// @notice Mapping of spent nullifiers
    mapping(bytes32 => bool) public spent;

    /// @notice Authorized contracts that can mark nullifiers as spent
    mapping(address => bool) public authorizedMarkers;

    /// @notice Owner address for authorization management
    address public owner;

    /// @notice Total number of spent nullifiers (for statistics)
    uint256 public totalSpent;

    error Unauthorized();
    error NullifierAlreadySpent();
    error ZeroNullifier();

    modifier onlyAuthorized() {
        if (!authorizedMarkers[msg.sender] && msg.sender != owner) {
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
        authorizedMarkers[msg.sender] = true;
    }

    /// @notice Authorize an address to mark nullifiers as spent
    /// @param marker The address to authorize
    function authorizeMarker(address marker) external onlyOwner {
        authorizedMarkers[marker] = true;
    }

    /// @notice Revoke authorization from an address
    /// @param marker The address to revoke
    function revokeMarker(address marker) external onlyOwner {
        authorizedMarkers[marker] = false;
    }

    /// @notice Transfer ownership
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    /// @inheritdoc IGhostNullifierRegistry
    function isSpent(bytes32 nullifier) external view returns (bool) {
        return spent[nullifier];
    }

    /// @inheritdoc IGhostNullifierRegistry
    /// @notice Mark a nullifier as spent to prevent double-redemption
    /// @dev Gas cost: ~25,000 gas (cold storage write) or ~5,000 gas (warm)
    ///
    ///      Security flow:
    ///      1. Reject zero nullifier (prevents accidental collisions)
    ///      2. Check not already spent (double-spend protection)
    ///      3. Mark spent BEFORE emitting event (prevents reentrancy issues)
    ///      4. Increment counter for statistics
    ///
    /// @param nullifier The nullifier to mark as spent
    ///
    /// @custom:security This function is the critical double-spend prevention mechanism.
    ///                  It MUST be called before minting tokens in redemption.
    /// @custom:reverts ZeroNullifier if nullifier is bytes32(0)
    /// @custom:reverts NullifierAlreadySpent if nullifier was previously spent
    function markSpent(bytes32 nullifier) external onlyAuthorized {
        if (nullifier == bytes32(0)) {
            revert ZeroNullifier();
        }
        if (spent[nullifier]) {
            revert NullifierAlreadySpent();
        }

        spent[nullifier] = true;
        totalSpent++;

        emit NullifierSpent(nullifier);
    }

    /// @notice Batch check if multiple nullifiers are spent
    /// @param nullifiers Array of nullifiers to check
    /// @return results Array of boolean results
    function batchIsSpent(bytes32[] calldata nullifiers) external view returns (bool[] memory results) {
        results = new bool[](nullifiers.length);
        for (uint256 i = 0; i < nullifiers.length; i++) {
            results[i] = spent[nullifiers[i]];
        }
    }
}
