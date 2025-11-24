// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostVerifier} from "../interfaces/IGhostContracts.sol";

/// @title MockGhostVerifier
/// @notice Mock verifier that always returns true - FOR TESTING ONLY
/// @dev Used to test Ghost Protocol flow without ZK proof verification
contract MockGhostVerifier is IGhostVerifier {
    /// @notice Always returns true - FOR TESTING ONLY
    function verifyRedemptionProof(
        bytes calldata,
        uint256[] calldata
    ) external pure override returns (bool) {
        return true;
    }

    /// @notice Always returns true - FOR TESTING ONLY
    function verifyPartialRedemptionProof(
        bytes calldata,
        uint256[] calldata
    ) external pure override returns (bool) {
        return true;
    }
}
