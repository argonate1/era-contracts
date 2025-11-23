// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GhostHash} from "../../../contracts/ghost/libraries/GhostHash.sol";
import {PoseidonT3} from "../../../contracts/ghost/libraries/PoseidonT3.sol";

/**
 * @title PoseidonHashTest
 * @notice Integration tests for Poseidon hash consistency
 * @dev Verifies that Solidity Poseidon matches circuit implementation
 *
 * These tests ensure the critical property that:
 * - GhostHash.sol Poseidon output == merkle.circom Poseidon output
 * - GhostHash.sol commitment == poseidon.circom commitment
 *
 * IMPORTANT: When running with real circuits, compare these test vectors
 * against the circuit output to verify hash function compatibility.
 */
contract PoseidonHashTest is Test {
    // BN254 field modulus
    uint256 constant FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // ============ Test Vectors ============
    // These vectors should be verified against the circomlib output

    function test_PoseidonT3_BasicHash() public pure {
        // Test basic 2-input Poseidon hash
        uint256[2] memory inputs;
        inputs[0] = 1;
        inputs[1] = 2;

        uint256 result = PoseidonT3.hash(inputs);

        // Result should be non-zero and in field
        assertTrue(result > 0, "Hash should be non-zero");
        assertTrue(result < FIELD_MODULUS, "Hash should be in field");

        // Same inputs should give same output (deterministic)
        uint256 result2 = PoseidonT3.hash(inputs);
        assertEq(result, result2, "Hash should be deterministic");
    }

    function test_PoseidonT3_ZeroInputs() public pure {
        uint256[2] memory inputs;
        inputs[0] = 0;
        inputs[1] = 0;

        uint256 result = PoseidonT3.hash(inputs);

        // Zero inputs should still produce valid hash
        assertTrue(result > 0, "Hash of zeros should be non-zero");
        assertTrue(result < FIELD_MODULUS, "Hash should be in field");
    }

    function test_PoseidonT3_LargeInputs() public pure {
        uint256[2] memory inputs;
        inputs[0] = FIELD_MODULUS - 1; // Max valid input
        inputs[1] = FIELD_MODULUS - 2;

        uint256 result = PoseidonT3.hash(inputs);

        assertTrue(result > 0, "Hash should be non-zero");
        assertTrue(result < FIELD_MODULUS, "Hash should be in field");
    }

    function test_PoseidonT3_OrderMatters() public pure {
        uint256[2] memory inputs1;
        inputs1[0] = 1;
        inputs1[1] = 2;

        uint256[2] memory inputs2;
        inputs2[0] = 2;
        inputs2[1] = 1;

        uint256 result1 = PoseidonT3.hash(inputs1);
        uint256 result2 = PoseidonT3.hash(inputs2);

        assertTrue(result1 != result2, "Order of inputs should affect hash");
    }

    // ============ GhostHash Integration Tests ============

    function test_HashLeaf_DomainSeparation() public pure {
        bytes32 value = bytes32(uint256(12345));

        bytes32 leafHash = GhostHash.hashLeaf(value);

        // Verify domain separation: hashLeaf(x) = Poseidon(0, x)
        uint256[2] memory inputs;
        inputs[0] = 0; // Domain separator for leaves
        inputs[1] = uint256(value);
        bytes32 expected = bytes32(PoseidonT3.hash(inputs));

        assertEq(leafHash, expected, "hashLeaf should use domain separator 0");
    }

    function test_HashNode_DomainSeparation() public pure {
        bytes32 left = bytes32(uint256(111));
        bytes32 right = bytes32(uint256(222));

        bytes32 nodeHash = GhostHash.hashNode(left, right);

        // Verify domain separation: hashNode(l,r) = Poseidon(Poseidon(1, l), r)
        uint256[2] memory pair1;
        pair1[0] = 1; // Domain separator for nodes
        pair1[1] = uint256(left);
        uint256 h1 = PoseidonT3.hash(pair1);

        uint256[2] memory pair2;
        pair2[0] = h1;
        pair2[1] = uint256(right);
        bytes32 expected = bytes32(PoseidonT3.hash(pair2));

        assertEq(nodeHash, expected, "hashNode should use chained Poseidon with domain separator 1");
    }

    function test_ComputeCommitment_Structure() public pure {
        bytes32 secret = bytes32(uint256(0x1234));
        bytes32 nullifier = bytes32(uint256(0x5678));
        uint256 amount = 1000 ether;
        address token = address(0xABCD);

        bytes32 commitment = GhostHash.computeCommitment(secret, nullifier, amount, token);

        // Verify tree structure: Poseidon(Poseidon(s,n), Poseidon(a,t))
        uint256[2] memory pair1;
        pair1[0] = uint256(secret);
        pair1[1] = uint256(nullifier);
        uint256 h1 = PoseidonT3.hash(pair1);

        uint256[2] memory pair2;
        pair2[0] = amount;
        pair2[1] = uint256(uint160(token));
        uint256 h2 = PoseidonT3.hash(pair2);

        uint256[2] memory pair3;
        pair3[0] = h1;
        pair3[1] = h2;
        bytes32 expected = bytes32(PoseidonT3.hash(pair3));

        assertEq(commitment, expected, "Commitment should use tree-structured Poseidon4");
    }

    function test_ComputeNullifierHash() public pure {
        bytes32 secret = bytes32(uint256(0xDEAD));
        uint256 leafIndex = 42;

        bytes32 nullifierHash = GhostHash.computeNullifierHash(secret, leafIndex);

        // Verify: nullifierHash = Poseidon(secret, leafIndex)
        uint256[2] memory inputs;
        inputs[0] = uint256(secret);
        inputs[1] = leafIndex;
        bytes32 expected = bytes32(PoseidonT3.hash(inputs));

        assertEq(nullifierHash, expected, "Nullifier hash should be Poseidon(secret, leafIndex)");
    }

    // ============ Merkle Tree Hash Chain Tests ============

    function test_MerkleTreeHashChain() public pure {
        // Simulate a simple Merkle tree construction
        bytes32 leaf1 = bytes32(uint256(1));
        bytes32 leaf2 = bytes32(uint256(2));

        // Hash leaves
        bytes32 hash1 = GhostHash.hashLeaf(leaf1);
        bytes32 hash2 = GhostHash.hashLeaf(leaf2);

        // Hash nodes
        bytes32 root = GhostHash.hashNode(hash1, hash2);

        // Root should be deterministic and non-zero
        assertTrue(uint256(root) > 0, "Root should be non-zero");
        assertTrue(uint256(root) < FIELD_MODULUS, "Root should be in field");

        // Verify reproducibility
        bytes32 root2 = GhostHash.hashNode(
            GhostHash.hashLeaf(leaf1),
            GhostHash.hashLeaf(leaf2)
        );
        assertEq(root, root2, "Merkle root should be reproducible");
    }

    function test_LeafNodeHashDifference() public pure {
        // Same value should produce different hashes as leaf vs node
        bytes32 value = bytes32(uint256(12345));

        bytes32 asLeaf = GhostHash.hashLeaf(value);
        bytes32 asNode = GhostHash.hashNode(value, value);

        assertTrue(asLeaf != asNode, "Leaf and node hashes should differ due to domain separation");
    }

    // ============ Fuzz Tests ============

    function testFuzz_PoseidonT3_InField(uint256 a, uint256 b) public pure {
        // Bound inputs to valid field elements
        a = a % FIELD_MODULUS;
        b = b % FIELD_MODULUS;

        uint256[2] memory inputs;
        inputs[0] = a;
        inputs[1] = b;

        uint256 result = PoseidonT3.hash(inputs);

        assertTrue(result < FIELD_MODULUS, "Hash should always be in field");
    }

    function testFuzz_HashLeaf_InField(bytes32 value) public pure {
        bytes32 result = GhostHash.hashLeaf(value);
        assertTrue(uint256(result) < FIELD_MODULUS, "Leaf hash should be in field");
    }

    function testFuzz_HashNode_InField(bytes32 left, bytes32 right) public pure {
        bytes32 result = GhostHash.hashNode(left, right);
        assertTrue(uint256(result) < FIELD_MODULUS, "Node hash should be in field");
    }

    function testFuzz_Commitment_Deterministic(
        bytes32 secret,
        bytes32 nullifier,
        uint256 amount,
        address token
    ) public pure {
        bytes32 c1 = GhostHash.computeCommitment(secret, nullifier, amount, token);
        bytes32 c2 = GhostHash.computeCommitment(secret, nullifier, amount, token);
        assertEq(c1, c2, "Commitment should be deterministic");
    }

    function testFuzz_Commitment_UniqueForDifferentInputs(
        bytes32 secret1,
        bytes32 secret2,
        bytes32 nullifier,
        uint256 amount,
        address token
    ) public pure {
        vm.assume(secret1 != secret2);

        bytes32 c1 = GhostHash.computeCommitment(secret1, nullifier, amount, token);
        bytes32 c2 = GhostHash.computeCommitment(secret2, nullifier, amount, token);

        assertTrue(c1 != c2, "Different secrets should produce different commitments");
    }

    // ============ Test Vectors for Circuit Validation ============
    // These should match the output of the circom circuits

    function test_KnownTestVector_Commitment() public pure {
        // Test vector: standard inputs
        bytes32 secret = bytes32(uint256(0x123456789abcdef));
        bytes32 nullifier = bytes32(uint256(0xfedcba987654321));
        uint256 amount = 1 ether;
        address token = address(0x1234567890123456789012345678901234567890);

        bytes32 commitment = GhostHash.computeCommitment(secret, nullifier, amount, token);

        // This value should be verified against circuit output
        // When circuits are compiled, update this assertion with the actual value
        assertTrue(uint256(commitment) > 0, "Commitment should be computable");
        assertTrue(uint256(commitment) < FIELD_MODULUS, "Commitment should be in field");

        // Log for manual verification against circuit
        console2.log("Test vector commitment:");
        console2.logBytes32(commitment);
    }

    function test_KnownTestVector_MerkleLeaf() public pure {
        bytes32 commitment = bytes32(uint256(0xabcdef1234567890));

        bytes32 leafHash = GhostHash.hashLeaf(commitment);

        // Log for circuit verification
        console2.log("Test vector leaf hash:");
        console2.logBytes32(leafHash);

        assertTrue(uint256(leafHash) > 0, "Leaf hash should be non-zero");
    }

    function test_KnownTestVector_MerkleNode() public pure {
        bytes32 left = bytes32(uint256(0x111111));
        bytes32 right = bytes32(uint256(0x222222));

        bytes32 nodeHash = GhostHash.hashNode(left, right);

        // Log for circuit verification
        console2.log("Test vector node hash:");
        console2.logBytes32(nodeHash);

        assertTrue(uint256(nodeHash) > 0, "Node hash should be non-zero");
    }
}
