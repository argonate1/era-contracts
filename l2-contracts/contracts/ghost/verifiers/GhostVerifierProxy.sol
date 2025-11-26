// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGhostVerifier} from "../interfaces/IGhostContracts.sol";
import {RedeemVerifierWorking} from "./RedeemVerifierWorking.sol";
import {PartialRedeemVerifier} from "./PartialRedeemVerifier.sol";

/// @title GhostVerifierProxy
/// @author Ghost Protocol Team
/// @notice ZK proof verification for ghost redemptions using Groth16
/// @dev This contract wraps pre-deployed Groth16 verifiers. Unlike GhostVerifier which
///      creates verifiers in the constructor (which fails on ZKsync due to factoryDeps),
///      this contract accepts addresses of already-deployed verifiers.
///
///      Deployment order for ZKsync:
///      1. Deploy RedeemVerifier
///      2. Deploy PartialRedeemVerifier
///      3. Deploy GhostVerifierProxy with both addresses
///
/// @custom:security-contact security@ghostprotocol.xyz
contract GhostVerifierProxy is IGhostVerifier {
    /// @notice The Groth16 verifier for full redemptions
    RedeemVerifierWorking public immutable redeemVerifier;

    /// @notice The Groth16 verifier for partial redemptions
    PartialRedeemVerifier public immutable partialRedeemVerifier;

    /// @notice Owner for admin operations
    address public owner;

    // Errors
    error Unauthorized();
    error InvalidProof();
    error InvalidProofLength();
    error InvalidPublicInputsLength();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }

    /// @notice Constructor accepts pre-deployed verifier addresses
    /// @param _redeemVerifier Address of deployed RedeemVerifier
    /// @param _partialRedeemVerifier Address of deployed PartialRedeemVerifier
    constructor(address _redeemVerifier, address _partialRedeemVerifier) {
        if (_redeemVerifier == address(0) || _partialRedeemVerifier == address(0)) {
            revert ZeroAddress();
        }
        owner = msg.sender;
        redeemVerifier = RedeemVerifierWorking(_redeemVerifier);
        partialRedeemVerifier = PartialRedeemVerifier(_partialRedeemVerifier);
    }

    /// @inheritdoc IGhostVerifier
    /// @notice Verify a full redemption proof
    /// @dev The proof bytes should be ABI-encoded as: (uint[2] a, uint[2][2] b, uint[2] c)
    ///      The publicInputs from GhostERC20 are: [merkleRoot, nullifier, amount, token, recipient]
    ///      We need to prepend the commitmentOut (which is computed by the circuit)
    function verifyRedemptionProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool) {
        // Validate public inputs length (5 from contract: merkleRoot, nullifier, amount, token, recipient)
        if (publicInputs.length < 5) {
            revert InvalidPublicInputsLength();
        }

        // Parse the Groth16 proof components
        // Expected format: abi.encode(uint[2] a, uint[2][2] b, uint[2] c)
        if (proof.length < 256) {
            revert InvalidProofLength();
        }

        (
            uint256[2] memory a,
            uint256[2][2] memory b,
            uint256[2] memory c,
            uint256 commitmentOut
        ) = abi.decode(proof, (uint256[2], uint256[2][2], uint256[2], uint256));

        // Build the full public signals array (6 elements)
        // Order: [commitmentOut, merkleRoot, nullifier, amount, tokenAddress, recipient]
        uint256[6] memory pubSignals;
        pubSignals[0] = commitmentOut;           // Circuit output (from proof)
        pubSignals[1] = publicInputs[0];         // merkleRoot
        pubSignals[2] = publicInputs[1];         // nullifier
        pubSignals[3] = publicInputs[2];         // amount
        pubSignals[4] = publicInputs[3];         // tokenAddress
        pubSignals[5] = publicInputs[4];         // recipient

        // Call the Groth16 verifier
        return redeemVerifier.verifyProof(a, b, c, pubSignals);
    }

    /// @inheritdoc IGhostVerifier
    /// @notice Verify a partial redemption proof
    /// @dev The proof bytes should be ABI-encoded with outputs included
    ///      The publicInputs from GhostERC20 are: [merkleRoot, oldNullifier, redeemAmount, token, recipient, originalAmount, redeemAmount, newCommitment]
    function verifyPartialRedemptionProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool) {
        // Validate public inputs length (8 from contract)
        if (publicInputs.length < 8) {
            revert InvalidPublicInputsLength();
        }

        // Parse the Groth16 proof components with circuit outputs
        if (proof.length < 288) {
            revert InvalidProofLength();
        }

        (
            uint256[2] memory a,
            uint256[2][2] memory b,
            uint256[2] memory c,
            uint256 oldCommitmentOut,
            uint256 newCommitmentOut,
            uint256 remainingAmountOut
        ) = abi.decode(proof, (uint256[2], uint256[2][2], uint256[2], uint256, uint256, uint256));

        // Build the full public signals array (10 elements)
        // Order: [oldCommitmentOut, newCommitmentOut, remainingAmountOut, merkleRoot, oldNullifier, redeemAmount, tokenAddress, recipient, originalAmount, newCommitment]
        uint256[10] memory pubSignals;
        pubSignals[0] = oldCommitmentOut;        // Circuit output
        pubSignals[1] = newCommitmentOut;        // Circuit output
        pubSignals[2] = remainingAmountOut;      // Circuit output
        pubSignals[3] = publicInputs[0];         // merkleRoot
        pubSignals[4] = publicInputs[1];         // oldNullifier
        pubSignals[5] = publicInputs[2];         // redeemAmount
        pubSignals[6] = publicInputs[3];         // tokenAddress
        pubSignals[7] = publicInputs[4];         // recipient
        pubSignals[8] = publicInputs[5];         // originalAmount
        pubSignals[9] = publicInputs[7];         // newCommitment (index 7 in contract's array)

        // Call the Groth16 verifier
        return partialRedeemVerifier.verifyProof(a, b, c, pubSignals);
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }
}
