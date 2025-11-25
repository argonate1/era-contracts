/**
 * Compute the precomputed Poseidon T3 zero hashes for CommitmentTree
 *
 * This script uses circomlibjs to compute the exact same values
 * that the PoseidonT3.sol library would compute.
 *
 * The resulting constants should be hardcoded into CommitmentTree.sol
 * to avoid expensive constructor hashing.
 */

import { buildPoseidon } from 'circomlibjs';

const TREE_DEPTH = 20;

async function main() {
  console.log("Computing Poseidon T3 Zero Hashes for CommitmentTree...\n");

  const poseidon = await buildPoseidon();
  const F = poseidon.F;

  const zeros = [];

  // Level 0: hashLeaf(bytes32(0)) = Poseidon(0, 0) with domain separator 0
  // In GhostHash.hashLeaf: Poseidon(0, value) where value = 0
  const level0 = poseidon([0n, 0n]);
  zeros.push(F.toObject(level0));

  console.log(`Level 0 (hashLeaf(0)): 0x${zeros[0].toString(16).padStart(64, '0')}`);

  // Levels 1-19: hashNode(zeros[i-1], zeros[i-1])
  // In GhostHash.hashNode:
  //   h1 = Poseidon(1, left)
  //   result = Poseidon(h1, right)
  for (let i = 1; i < TREE_DEPTH; i++) {
    const prevZero = zeros[i - 1];

    // h1 = Poseidon(1, prevZero) - domain separator 1 for internal nodes
    const h1 = poseidon([1n, prevZero]);
    const h1Value = F.toObject(h1);

    // result = Poseidon(h1, prevZero)
    const result = poseidon([h1Value, prevZero]);
    const resultValue = F.toObject(result);

    zeros.push(resultValue);
    console.log(`Level ${i} (hashNode): 0x${resultValue.toString(16).padStart(64, '0')}`);
  }

  // Compute initial root: hashNode(zeros[TREE_DEPTH-1], zeros[TREE_DEPTH-1])
  const lastZero = zeros[TREE_DEPTH - 1];
  const rootH1 = poseidon([1n, lastZero]);
  const rootH1Value = F.toObject(rootH1);
  const initialRoot = poseidon([rootH1Value, lastZero]);
  const initialRootValue = F.toObject(initialRoot);

  console.log(`\nInitial Root: 0x${initialRootValue.toString(16).padStart(64, '0')}`);

  // Output Solidity code
  console.log("\n\n// ========================================");
  console.log("// Solidity Constants for CommitmentTree");
  console.log("// ========================================\n");

  console.log("/// @notice Precomputed Poseidon zero hashes for each tree level");
  console.log("/// @dev These MUST match the circomlibjs/snarkjs Poseidon implementation");
  console.log("/// @dev Computed using: zeros[0] = hashLeaf(0), zeros[i] = hashNode(zeros[i-1], zeros[i-1])");
  console.log("bytes32 private constant ZERO_0 = bytes32(0x" + zeros[0].toString(16).padStart(64, '0') + ");");
  for (let i = 1; i < TREE_DEPTH; i++) {
    console.log(`bytes32 private constant ZERO_${i} = bytes32(0x${zeros[i].toString(16).padStart(64, '0')});`);
  }

  console.log("\n/// @notice Initial tree root (empty tree)");
  console.log(`bytes32 private constant INITIAL_ROOT = bytes32(0x${initialRootValue.toString(16).padStart(64, '0')});`);

  console.log("\n// Array version for loop initialization:");
  console.log("function _getZeroHash(uint256 level) internal pure returns (bytes32) {");
  for (let i = 0; i < TREE_DEPTH; i++) {
    console.log(`    if (level == ${i}) return ZERO_${i};`);
  }
  console.log("    revert(\"Invalid level\");");
  console.log("}");
}

main().catch(console.error);
