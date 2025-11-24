// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostVerifier} from "../interfaces/IGhostContracts.sol";

/// @title TestVerifier
/// @notice Simple test verifier that always returns true
/// @dev Used for testing Ghost Protocol deployment on ZKsync
///      No nested contract deployments in constructor
contract TestVerifier is IGhostVerifier {
    /// @notice Owner for potential admin operations
    address public immutable owner;

    /// @notice Whether this verifier requires real proofs (always false for test)
    bool public constant requiresRealProofs = false;

    constructor() {
        owner = msg.sender;
    }

    /// @notice Always returns true for testing
    function verifyRedemptionProof(
        bytes calldata,
        uint256[] calldata
    ) external pure override returns (bool) {
        return true;
    }

    /// @notice Always returns true for testing
    function verifyPartialRedemptionProof(
        bytes calldata,
        uint256[] calldata
    ) external pure override returns (bool) {
        return true;
    }
}
