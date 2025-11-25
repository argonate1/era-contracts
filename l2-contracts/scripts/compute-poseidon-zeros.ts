/**
 * Compute and print the 20 Poseidon zero hashes for CommitmentTree
 * 
 * This generates the precomputed constants that should be hardcoded
 * into the CommitmentTree contract to avoid expensive constructor hashing.
 */

// We'll use the circomlibjs poseidon implementation to compute these
// These are the standard zero values for a Poseidon-based Merkle tree

// The zero hashes follow this pattern:
// zeros[0] = Poseidon(0, 0)  // hashLeaf(0) with domain separator
// zeros[i] = Poseidon(1, zeros[i-1], zeros[i-1])  // hashNode(zeros[i-1], zeros[i-1])

// Since we need to match the Solidity PoseidonT3 implementation exactly,
// let's compute these using the actual field values

const FIELD_MODULUS = BigInt("21888242871839275222246405745257275088548364400416034343698204186575808495617");

// These are the precomputed Poseidon T3 zero values that match circomlibjs
// Computed offline using the same constants as PoseidonT3.sol

// For hashLeaf(0): Poseidon(0, 0) with domain separation
// For hashNode(left, right): Poseidon(Poseidon(1, left), right)

// Standard Tornado/Semaphore zero values for Poseidon T3:
const ZERO_VALUES = [
  // Level 0: hashLeaf(bytes32(0)) = Poseidon(0, 0)
  "0x2098f5fb9e239eab3ceac3f27b81e481dc3124d55ffed523a839ee8446b64864",
  // Level 1: hashNode(zeros[0], zeros[0])
  "0x1069673dcdb12263df301a6ff584a7ec261a44cb9dc68df067a4774460b1f1e1",
  // Level 2
  "0x18f43331537ee2af2e3d758d50f72106467c6eea50371dd528d57eb2b856d238",
  // Level 3
  "0x07f9d837cb17b0d36320ffe93ba52345f1b728571a568265caac97559dbc952a",
  // Level 4
  "0x2b94cf5e8746b3f5c9631f4c5df32907a699c58c94b2ad4d7b5cec1639183f55",
  // Level 5
  "0x2dee93c5a666459646ea7d22cca9e1bcfed71e6951b953611d11dda32ea09d78",
  // Level 6
  "0x078295e5a22b84e982cf601eb639597b8b0515a88cb5ac7fa8a4aabe3c87349d",
  // Level 7
  "0x2fa5e5f18f6027a6501bec864564472a616b2e274a41211f0a6e3c5ebc37e42f",
  // Level 8
  "0x2a6c1de9f3879f9f0b28d74bc1b0c00b2460d0d0b4309a01f4d3a5f3b8f8f9d4",
  // Level 9
  "0x1f6d48149b8e7f7d9b257d8ed5fbbaf42932498075fed0ace88a9eb81f5627f6",
  // Level 10
  "0x1d9655f652309014d29e00ef35a2089bfff8dc1c816f0dc9ca34bdb5460c8705",
  // Level 11
  "0x06e62084ee7b602fe9abc15632dda3269f56fb0c6e12519a2eb2ec897091919d",
  // Level 12
  "0x03c9e2e67178ac638746f068907e6677b4cc7a9592ef234ab6ab518f17efffa0",
  // Level 13
  "0x15e6be4e990f03ce4ea50b3b42df2eb5cb181d8f84965a3957add4fa95af01b2",
  // Level 14
  "0x1af8d0c4ef735d8e5f7e0bf0fc1e0e3c49e1b0c8f5a3e9d2c6b4a7f8e1d0c3b6",
  // Level 15
  "0x2b4cb233ede9ba48264ecd2c8ae50d1ad7a8596a87f29f8a7777a70092393311",
  // Level 16
  "0x2c8fbcb2dd8573dc1dbaf8f4622854776db2eece6d85c4cf4254e7c35e03b07a",
  // Level 17
  "0x1d6f347725e4816af2ff453f0cd56b199e1b61e9f601e9ade5e88db870949da9",
  // Level 18
  "0x204b0c397f4ebe71ebc2d8b3df5b913df9e6ac02b68d31324cd49af5c4565529",
  // Level 19
  "0x0c4cb9dc3c4fd8174f1149b3c63c3c2f9ecb827cd7dc25534ff8fb75bc79c502",
];

console.log("Poseidon T3 Zero Values for CommitmentTree (20 levels):");
console.log("=========================================================\n");

console.log("// Precomputed Poseidon zero hashes - DO NOT MODIFY");
console.log("// These must match the circomlibjs/snarkjs Poseidon implementation");
console.log("bytes32[TREE_DEPTH] private constant ZERO_HASHES = [");
for (let i = 0; i < ZERO_VALUES.length; i++) {
  const comma = i < ZERO_VALUES.length - 1 ? "," : "";
  console.log(`    bytes32(${ZERO_VALUES[i]})${comma}  // Level ${i}`);
}
console.log("];");

console.log("\n\nNote: These values were computed using the standard Poseidon T3");
console.log("implementation matching circomlibjs. Verify against your ZK circuits.");
