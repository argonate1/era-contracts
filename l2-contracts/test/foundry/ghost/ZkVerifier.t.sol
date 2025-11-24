// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RedeemVerifier} from "../../../contracts/ghost/verifiers/RedeemVerifier.sol";
import {PartialRedeemVerifier} from "../../../contracts/ghost/verifiers/PartialRedeemVerifier.sol";
import {ProductionVerifier} from "../../../contracts/ghost/verifiers/ProductionVerifier.sol";

/**
 * @title ZkVerifierTest
 * @notice Integration tests for ZK verifier contracts
 * @dev Tests the Groth16 verifier interface and integration with GhostERC20
 *
 * Public Input Ordering:
 *
 * RedeemVerifier (6 signals):
 * [0] output - commitment validation flag
 * [1] merkleRoot
 * [2] nullifier
 * [3] amount
 * [4] tokenAddress
 * [5] recipient
 *
 * PartialRedeemVerifier (10 signals):
 * [0] newNullifierHash (output)
 * [1] newCommitment (output)
 * [2] valid (output flag)
 * [3] merkleRoot
 * [4] oldNullifierHash
 * [5] redeemAmount
 * [6] remainingAmount
 * [7] tokenAddress
 * [8] recipient
 * [9] currentTimestamp
 */
contract ZkVerifierTest is Test {
    RedeemVerifier public redeemVerifier;
    PartialRedeemVerifier public partialRedeemVerifier;
    ProductionVerifier public productionVerifier;

    // BN254 curve parameters
    uint256 constant SCALAR_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 constant BASE_FIELD = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    function setUp() public {
        redeemVerifier = new RedeemVerifier();
        partialRedeemVerifier = new PartialRedeemVerifier();

        // Production verifier deploys its own verifier instances
        productionVerifier = new ProductionVerifier();
    }

    // ============ Redeem Verifier Tests ============

    function test_RedeemVerifier_DeploysSuccessfully() public view {
        assertTrue(address(redeemVerifier) != address(0), "Verifier should deploy");
    }

    function test_RedeemVerifier_RejectsInvalidProof() public view {
        // Create a dummy proof
        uint256[2] memory pA = [uint256(1), uint256(2)];
        uint256[2][2] memory pB = [[uint256(1), uint256(2)], [uint256(3), uint256(4)]];
        uint256[2] memory pC = [uint256(1), uint256(2)];

        // 6 public signals: [output, merkleRoot, nullifier, amount, tokenAddress, recipient]
        uint256[6] memory pubSignals;
        pubSignals[0] = 0; // output (valid commitment flag)
        pubSignals[1] = 0x1234; // merkleRoot
        pubSignals[2] = 0x5678; // nullifier
        pubSignals[3] = 1 ether; // amount
        pubSignals[4] = uint256(uint160(address(0xABCD))); // token
        pubSignals[5] = uint256(uint160(address(0xDEAD))); // recipient

        // Real verifier rejects invalid proofs
        bool result = redeemVerifier.verifyProof(pA, pB, pC, pubSignals);
        assertFalse(result, "Should reject invalid proofs");
    }

    function test_RedeemVerifier_RejectsOutOfFieldSignals() public view {
        uint256[2] memory pA = [uint256(1), uint256(2)];
        uint256[2][2] memory pB = [[uint256(1), uint256(2)], [uint256(3), uint256(4)]];
        uint256[2] memory pC = [uint256(1), uint256(2)];

        // Signal exceeds scalar field
        uint256[6] memory pubSignals;
        pubSignals[0] = SCALAR_FIELD; // Out of field!
        pubSignals[1] = 0x1234;
        pubSignals[2] = 0x5678;
        pubSignals[3] = 1 ether;
        pubSignals[4] = uint256(uint160(address(0xABCD)));
        pubSignals[5] = uint256(uint160(address(0xDEAD)));

        bool result = redeemVerifier.verifyProof(pA, pB, pC, pubSignals);
        assertFalse(result, "Should reject out-of-field signals");
    }

    function test_RedeemVerifier_RejectsOutOfCurveProofPoints() public view {
        // Proof point exceeds base field
        uint256[2] memory pA = [BASE_FIELD, uint256(2)]; // Out of curve!
        uint256[2][2] memory pB = [[uint256(1), uint256(2)], [uint256(3), uint256(4)]];
        uint256[2] memory pC = [uint256(1), uint256(2)];

        uint256[6] memory pubSignals;
        pubSignals[0] = 0;
        pubSignals[1] = 0x1234;
        pubSignals[2] = 0x5678;
        pubSignals[3] = 1 ether;
        pubSignals[4] = uint256(uint160(address(0xABCD)));
        pubSignals[5] = uint256(uint160(address(0xDEAD)));

        bool result = redeemVerifier.verifyProof(pA, pB, pC, pubSignals);
        assertFalse(result, "Should reject out-of-curve proof points");
    }

    // ============ Partial Redeem Verifier Tests ============

    function test_PartialRedeemVerifier_DeploysSuccessfully() public view {
        assertTrue(address(partialRedeemVerifier) != address(0), "Partial verifier should deploy");
    }

    function test_PartialRedeemVerifier_RejectsInvalidProof() public view {
        uint256[2] memory pA = [uint256(1), uint256(2)];
        uint256[2][2] memory pB = [[uint256(1), uint256(2)], [uint256(3), uint256(4)]];
        uint256[2] memory pC = [uint256(1), uint256(2)];

        // 10 public signals for partial redeem
        uint256[10] memory pubSignals;
        pubSignals[0] = 0xDEF0; // newNullifierHash (output)
        pubSignals[1] = 0x9ABC; // newCommitment (output)
        pubSignals[2] = 1; // valid (output)
        pubSignals[3] = 0x1234; // merkleRoot
        pubSignals[4] = 0x5678; // oldNullifierHash
        pubSignals[5] = 0.5 ether; // redeemAmount
        pubSignals[6] = 0.5 ether; // remainingAmount
        pubSignals[7] = uint256(uint160(address(0xABCD))); // token
        pubSignals[8] = uint256(uint160(address(0xDEAD))); // recipient
        pubSignals[9] = block.timestamp; // currentTimestamp

        bool result = partialRedeemVerifier.verifyProof(pA, pB, pC, pubSignals);
        assertFalse(result, "Should reject invalid proofs");
    }

    function test_PartialRedeemVerifier_AllSignalsInField() public view {
        uint256[2] memory pA = [uint256(1), uint256(2)];
        uint256[2][2] memory pB = [[uint256(1), uint256(2)], [uint256(3), uint256(4)]];
        uint256[2] memory pC = [uint256(1), uint256(2)];

        // All signals must be < SCALAR_FIELD (10 signals for partial redeem)
        uint256[10] memory pubSignals;
        pubSignals[0] = SCALAR_FIELD - 1; // Max valid
        pubSignals[1] = SCALAR_FIELD - 2;
        pubSignals[2] = SCALAR_FIELD - 3;
        pubSignals[3] = SCALAR_FIELD - 4;
        pubSignals[4] = SCALAR_FIELD - 5;
        pubSignals[5] = SCALAR_FIELD - 6;
        pubSignals[6] = SCALAR_FIELD - 7;
        pubSignals[7] = SCALAR_FIELD - 8;
        pubSignals[8] = SCALAR_FIELD - 9;
        pubSignals[9] = SCALAR_FIELD - 10;

        // Should not revert, just return false for invalid proof
        bool result = partialRedeemVerifier.verifyProof(pA, pB, pC, pubSignals);
        assertFalse(result, "Should return false even with valid field elements");
    }

    // ============ Production Verifier Tests ============

    function test_ProductionVerifier_DeploysWithEmbeddedVerifiers() public view {
        assertTrue(address(productionVerifier.redeemVerifier()) != address(0), "Redeem verifier should be deployed");
        assertTrue(address(productionVerifier.partialRedeemVerifier()) != address(0), "Partial verifier should be deployed");
    }

    function test_ProductionVerifier_VerifyRedemptionDelegates() public view {
        bytes memory proof = _createDummyProofBytes();

        // 6 public inputs for redeem
        uint256[] memory pubSignals = new uint256[](6);
        pubSignals[0] = 0; // output
        pubSignals[1] = 0x1234; // merkleRoot
        pubSignals[2] = 0x5678; // nullifier
        pubSignals[3] = 1 ether; // amount
        pubSignals[4] = uint256(uint160(address(0xABCD))); // token
        pubSignals[5] = uint256(uint160(address(0xDEAD))); // recipient

        // Should delegate to RedeemVerifier and fail (invalid proof)
        bool result = productionVerifier.verifyRedemptionProof(proof, pubSignals);
        assertFalse(result, "Should delegate to verifier and fail with invalid proof");
    }

    function test_ProductionVerifier_VerifyPartialRedemptionDelegates() public view {
        bytes memory proof = _createDummyProofBytes();

        // 10 public inputs for partial redeem
        uint256[] memory pubSignals = new uint256[](10);
        pubSignals[0] = 0xDEF0; // newNullifierHash (output)
        pubSignals[1] = 0x9ABC; // newCommitment (output)
        pubSignals[2] = 1; // valid (output)
        pubSignals[3] = 0x1234; // merkleRoot
        pubSignals[4] = 0x5678; // oldNullifierHash
        pubSignals[5] = 0.5 ether; // redeemAmount
        pubSignals[6] = 0.5 ether; // remainingAmount
        pubSignals[7] = uint256(uint160(address(0xABCD))); // token
        pubSignals[8] = uint256(uint160(address(0xDEAD))); // recipient
        pubSignals[9] = block.timestamp; // currentTimestamp

        // Should delegate to PartialRedeemVerifier and fail (invalid proof)
        bool result = productionVerifier.verifyPartialRedemptionProof(proof, pubSignals);
        assertFalse(result, "Should delegate to verifier and fail with invalid proof");
    }

    function test_ProductionVerifier_RejectsWrongInputLength_Redeem() public {
        bytes memory proof = _createDummyProofBytes();

        // Wrong length: 5 instead of 6
        uint256[] memory pubSignals = new uint256[](5);
        pubSignals[0] = 0x1234;
        pubSignals[1] = 0x5678;
        pubSignals[2] = 1 ether;
        pubSignals[3] = uint256(uint160(address(0xABCD)));
        pubSignals[4] = uint256(uint160(address(0xDEAD)));

        vm.expectRevert(ProductionVerifier.InvalidInputLength.selector);
        productionVerifier.verifyRedemptionProof(proof, pubSignals);
    }

    function test_ProductionVerifier_RejectsWrongInputLength_PartialRedeem() public {
        bytes memory proof = _createDummyProofBytes();

        // Wrong length: 7 instead of 10
        uint256[] memory pubSignals = new uint256[](7);
        pubSignals[0] = 0x1234;
        pubSignals[1] = 0x5678;
        pubSignals[2] = 0.5 ether;
        pubSignals[3] = uint256(uint160(address(0xABCD)));
        pubSignals[4] = uint256(uint160(address(0xDEAD)));
        pubSignals[5] = 1 ether;
        pubSignals[6] = 0x9ABC;

        vm.expectRevert(ProductionVerifier.InvalidInputLength.selector);
        productionVerifier.verifyPartialRedemptionProof(proof, pubSignals);
    }

    function test_ProductionVerifier_RejectsOutOfFieldInputs() public {
        bytes memory proof = _createDummyProofBytes();

        uint256[] memory pubSignals = new uint256[](6);
        pubSignals[0] = SCALAR_FIELD; // Out of field!
        pubSignals[1] = 0x5678;
        pubSignals[2] = 0x9ABC;
        pubSignals[3] = 1 ether;
        pubSignals[4] = uint256(uint160(address(0xABCD)));
        pubSignals[5] = uint256(uint160(address(0xDEAD)));

        vm.expectRevert(ProductionVerifier.InputOutOfField.selector);
        productionVerifier.verifyRedemptionProof(proof, pubSignals);
    }

    function test_ProductionVerifier_RejectsShortProof() public {
        bytes memory shortProof = new bytes(100); // Too short (need 256)

        uint256[] memory pubSignals = new uint256[](6);
        pubSignals[0] = 0;
        pubSignals[1] = 0x1234;
        pubSignals[2] = 0x5678;
        pubSignals[3] = 1 ether;
        pubSignals[4] = uint256(uint160(address(0xABCD)));
        pubSignals[5] = uint256(uint160(address(0xDEAD)));

        vm.expectRevert(ProductionVerifier.InvalidProofLength.selector);
        productionVerifier.verifyRedemptionProof(shortProof, pubSignals);
    }

    function test_ProductionVerifier_OwnerCanTransfer() public {
        address newOwner = address(0x1234);
        productionVerifier.transferOwnership(newOwner);
        assertEq(productionVerifier.owner(), newOwner);
    }

    function test_ProductionVerifier_OnlyOwnerCanTransfer() public {
        address attacker = address(0xBAD);

        vm.prank(attacker);
        vm.expectRevert(ProductionVerifier.Unauthorized.selector);
        productionVerifier.transferOwnership(attacker);
    }

    function test_ProductionVerifier_CannotTransferToZero() public {
        vm.expectRevert(ProductionVerifier.ZeroAddress.selector);
        productionVerifier.transferOwnership(address(0));
    }

    /// @notice Helper to create properly formatted Groth16 proof bytes
    function _createDummyProofBytes() internal pure returns (bytes memory) {
        uint256[2] memory pA = [uint256(1), uint256(2)];
        uint256[2][2] memory pB = [[uint256(3), uint256(4)], [uint256(5), uint256(6)]];
        uint256[2] memory pC = [uint256(7), uint256(8)];
        return abi.encode(pA, pB, pC);
    }

    // ============ Groth16 Proof Structure Tests ============

    function test_ProofStructure_CorrectEncoding() public pure {
        // Test that proof structure matches expected ABI encoding
        uint256[2] memory pA = [uint256(1), uint256(2)];
        uint256[2][2] memory pB = [[uint256(3), uint256(4)], [uint256(5), uint256(6)]];
        uint256[2] memory pC = [uint256(7), uint256(8)];

        // Encode as expected by verifier
        bytes memory encoded = abi.encode(pA, pB, pC);

        // Decode back
        (uint256[2] memory decodedA, uint256[2][2] memory decodedB, uint256[2] memory decodedC) =
            abi.decode(encoded, (uint256[2], uint256[2][2], uint256[2]));

        assertEq(decodedA[0], pA[0], "pA[0] should match");
        assertEq(decodedA[1], pA[1], "pA[1] should match");
        assertEq(decodedB[0][0], pB[0][0], "pB[0][0] should match");
        assertEq(decodedB[0][1], pB[0][1], "pB[0][1] should match");
        assertEq(decodedB[1][0], pB[1][0], "pB[1][0] should match");
        assertEq(decodedB[1][1], pB[1][1], "pB[1][1] should match");
        assertEq(decodedC[0], pC[0], "pC[0] should match");
        assertEq(decodedC[1], pC[1], "pC[1] should match");
    }

    // ============ Fuzz Tests ============

    function testFuzz_RedeemVerifier_NoReverts(
        uint256 pA0, uint256 pA1,
        uint256 pB00, uint256 pB01, uint256 pB10, uint256 pB11,
        uint256 pC0, uint256 pC1,
        uint256[6] memory pubSignals
    ) public view {
        // Bound to valid curve points
        pA0 = bound(pA0, 0, BASE_FIELD - 1);
        pA1 = bound(pA1, 0, BASE_FIELD - 1);
        pC0 = bound(pC0, 0, BASE_FIELD - 1);
        pC1 = bound(pC1, 0, BASE_FIELD - 1);

        // Bound signals to valid field elements
        for (uint i = 0; i < 6; i++) {
            pubSignals[i] = bound(pubSignals[i], 0, SCALAR_FIELD - 1);
        }

        uint256[2] memory pA = [pA0, pA1];
        uint256[2][2] memory pB = [[pB00, pB01], [pB10, pB11]];
        uint256[2] memory pC = [pC0, pC1];

        // Should not revert with valid inputs
        redeemVerifier.verifyProof(pA, pB, pC, pubSignals);
    }

    function testFuzz_PartialRedeemVerifier_NoReverts(
        uint256 pA0, uint256 pA1,
        uint256 pC0, uint256 pC1,
        uint256[10] memory pubSignals
    ) public view {
        // Bound to valid curve points
        pA0 = bound(pA0, 0, BASE_FIELD - 1);
        pA1 = bound(pA1, 0, BASE_FIELD - 1);
        pC0 = bound(pC0, 0, BASE_FIELD - 1);
        pC1 = bound(pC1, 0, BASE_FIELD - 1);

        // Bound signals to valid field elements
        for (uint i = 0; i < 10; i++) {
            pubSignals[i] = bound(pubSignals[i], 0, SCALAR_FIELD - 1);
        }

        uint256[2] memory pA = [pA0, pA1];
        uint256[2][2] memory pB = [[uint256(1), uint256(2)], [uint256(3), uint256(4)]];
        uint256[2] memory pC = [pC0, pC1];

        // Should not revert with valid inputs
        partialRedeemVerifier.verifyProof(pA, pB, pC, pubSignals);
    }

    // ============ Gas Benchmarks ============

    function test_Gas_RedeemVerification() public view {
        uint256[2] memory pA = [uint256(1), uint256(2)];
        uint256[2][2] memory pB = [[uint256(1), uint256(2)], [uint256(3), uint256(4)]];
        uint256[2] memory pC = [uint256(1), uint256(2)];
        uint256[6] memory pubSignals;
        pubSignals[0] = 0;
        pubSignals[1] = 0x1234;
        pubSignals[2] = 0x5678;
        pubSignals[3] = 1 ether;
        pubSignals[4] = uint256(uint160(address(0xABCD)));
        pubSignals[5] = uint256(uint160(address(0xDEAD)));

        uint256 gasBefore = gasleft();
        redeemVerifier.verifyProof(pA, pB, pC, pubSignals);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Redeem verification gas:", gasUsed);
        // Real Groth16 verifier uses ~200k gas for pairing operations
    }

    function test_Gas_PartialRedeemVerification() public view {
        uint256[2] memory pA = [uint256(1), uint256(2)];
        uint256[2][2] memory pB = [[uint256(1), uint256(2)], [uint256(3), uint256(4)]];
        uint256[2] memory pC = [uint256(1), uint256(2)];
        uint256[10] memory pubSignals;
        pubSignals[0] = 0xDEF0; // newNullifierHash (output)
        pubSignals[1] = 0x9ABC; // newCommitment (output)
        pubSignals[2] = 1; // valid (output)
        pubSignals[3] = 0x1234; // merkleRoot
        pubSignals[4] = 0x5678; // oldNullifierHash
        pubSignals[5] = 0.5 ether; // redeemAmount
        pubSignals[6] = 0.5 ether; // remainingAmount
        pubSignals[7] = uint256(uint160(address(0xABCD))); // token
        pubSignals[8] = uint256(uint160(address(0xDEAD))); // recipient
        pubSignals[9] = block.timestamp; // currentTimestamp

        uint256 gasBefore = gasleft();
        partialRedeemVerifier.verifyProof(pA, pB, pC, pubSignals);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Partial redeem verification gas:", gasUsed);
    }

    function test_Gas_ProductionVerifierRedemption() public view {
        bytes memory proof = _createDummyProofBytes();

        uint256[] memory pubSignals = new uint256[](6);
        pubSignals[0] = 0;
        pubSignals[1] = 0x1234;
        pubSignals[2] = 0x5678;
        pubSignals[3] = 1 ether;
        pubSignals[4] = uint256(uint160(address(0xABCD)));
        pubSignals[5] = uint256(uint160(address(0xDEAD)));

        uint256 gasBefore = gasleft();
        productionVerifier.verifyRedemptionProof(proof, pubSignals);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("ProductionVerifier redemption gas:", gasUsed);
    }
}

/**
 * @title ZkVerifierRealProofTest
 * @notice Tests with real proofs (to be enabled after circuit compilation)
 * @dev Uncomment and update after running:
 *      cd contracts/l2-contracts/circuits/ghost
 *      npm run build:all
 */
contract ZkVerifierRealProofTest is Test {
    /*
    // After circuit compilation, add real test vectors here:

    function test_RealProof_RedeemCircuit() public {
        RedeemVerifier verifier = new RedeemVerifier();

        // Proof from snarkjs.groth16.fullProve()
        uint256[2] memory pA = [
            0x..., // Replace with real proof A[0]
            0x...  // Replace with real proof A[1]
        ];
        uint256[2][2] memory pB = [
            [0x..., 0x...], // Replace with real proof B
            [0x..., 0x...]
        ];
        uint256[2] memory pC = [
            0x..., // Replace with real proof C[0]
            0x...  // Replace with real proof C[1]
        ];

        // Public signals matching the proof (6 signals)
        uint256[6] memory pubSignals = [
            0x..., // output
            0x..., // merkleRoot
            0x..., // nullifier
            0x..., // amount
            0x..., // tokenAddress
            0x...  // recipient
        ];

        bool result = verifier.verifyProof(pA, pB, pC, pubSignals);
        assertTrue(result, "Real proof should verify");
    }
    */

    function test_Placeholder_SkipRealProofs() public pure {
        // This test exists as a placeholder
        // Real proof tests will be added after circuit compilation
        assertTrue(true, "Real proof tests pending circuit compilation");
    }
}
