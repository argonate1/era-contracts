/**
 * Verify ZERO_HASHES in CommitmentTree.sol against circomlibjs Poseidon
 *
 * This script computes the expected ZERO_HASHES using circomlibjs
 * and compares them against the values hardcoded in CommitmentTree.sol.
 *
 * Domain separation:
 * - hashLeaf(x) = Poseidon(0, x)  -- 0 prefix for leaves
 * - hashNode(l, r) = Poseidon(Poseidon(1, l), r) -- 1 prefix for internal nodes
 *
 * Usage: node verify-zero-hashes.mjs
 */

import { buildPoseidon } from 'circomlibjs';

const TREE_DEPTH = 20;

// Current values from CommitmentTree.sol (lines 52-74)
const CONTRACT_ZEROS = [
  '0x2098f5fb9e239eab3ceac3f27b81e481dc3124d55ffed523a839ee8446b64864', // ZERO_0
  '0x03000ecf278f3c3309f2a3a091b4d20b5e01f2b4e8f5b2a44bd4e2e67aa9a3d5', // ZERO_1
  '0x095484dd74b7944d4e4d47e9096b7b3fdb47343c0255cad9f778a4d860d09ee5', // ZERO_2
  '0x21913e227ee918b857420c4837a5a1f82defd33adca16dd5b1353f2fc4fb2efa', // ZERO_3
  '0x175db7f7731e9565bc2af37969333fe0dab6843a14dfa1907586d7b27079ddd2', // ZERO_4
  '0x1dc5be2455888701d738ef0ed32269376674b70b29a98980123347c5f2e967c5', // ZERO_5
  '0x2c6aac3d8b0da0e925de393b6abc9b9bc58d376f7c96c993fc733cb62a3c7272', // ZERO_6
  '0x05fc5c5dfefe7859bca0ae4a179400e63b18ac72ca10ef02b148852a21873177', // ZERO_7
  '0x116928f3286b4b999fb2010eaaed408acb058f25dbfd867143781f42747109bc', // ZERO_8
  '0x19fa904f32bbf12ed8e6b7fc57e310f4e5c27df2a7f2e017e1fdca68c3c3b857', // ZERO_9
  '0x2e6050e163fb37aeebfe94deccf4775ee9455e29e0aa861752c88f7602b3ba06', // ZERO_10
  '0x1f76931b305364224bcacc42880dc2ff0a3b121731c1bfc51d1d3cf59aa9e2fc', // ZERO_11
  '0x2ad3686f3debb1053171196e707e18641b7d079146e4146c16d2f57e7fffc72f', // ZERO_12
  '0x1487c599c5bae949fa13110ef123180c762cb17753b9166ab6398d2b970ae3bc', // ZERO_13
  '0x277111dc4f0e23a973df71f76a8c17cda8e2aad1dd010e68a7e15b7163a809c5', // ZERO_14
  '0x2782cd7c15ff4afac6c60fce7ec4be3dcf598cb69be3a267114d90ec94b53cd6', // ZERO_15
  '0x0624dca96d09cf0a4bf1c1a9e452848dd3013b1e00de113aac53ba1217f4ba72', // ZERO_16
  '0x264fa1f86bc354489576add848f5585d7b1c9b6609235563b789864a9e39ca91', // ZERO_17
  '0x0236580b7b4dbb2719ea53c5e2fcf9259e580800e42e4145b5845cc3a29abd6b', // ZERO_18
  '0x053dd6649e7fdffa6e409408ae272bcf70e385966564478ad63217c3b910b5f8', // ZERO_19
];
const CONTRACT_INITIAL_ROOT = '0x0b4a6c626bd085f652fb17cad5b70c9db903266b5a3f456ea6373a3cf97f3453';

async function main() {
  console.log("=".repeat(70));
  console.log("  GHOST PROTOCOL ZERO_HASHES VERIFICATION");
  console.log("  Using circomlibjs Poseidon implementation");
  console.log("=".repeat(70));
  console.log();

  const poseidon = await buildPoseidon();
  const F = poseidon.F;

  const computedZeros = [];
  let mismatches = 0;
  const mismatchDetails = [];

  // Level 0: hashLeaf(0) = Poseidon(0, 0)
  const level0 = poseidon([0n, 0n]);
  computedZeros.push(F.toObject(level0));

  console.log("LEVEL 0 (hashLeaf(0) = Poseidon(0, 0)):");
  const computed0 = '0x' + computedZeros[0].toString(16).padStart(64, '0');
  const match0 = computed0.toLowerCase() === CONTRACT_ZEROS[0].toLowerCase();
  console.log(`  Contract: ${CONTRACT_ZEROS[0]}`);
  console.log(`  Computed: ${computed0}`);
  console.log(`  Status:   ${match0 ? 'MATCH' : 'MISMATCH'}`);
  console.log();

  if (!match0) {
    mismatches++;
    mismatchDetails.push({ level: 0, contract: CONTRACT_ZEROS[0], computed: computed0 });
  }

  // Levels 1-19: hashNode(zeros[i-1], zeros[i-1])
  // hashNode(l, r) = Poseidon(Poseidon(1, l), r)
  for (let i = 1; i < TREE_DEPTH; i++) {
    const prevZero = computedZeros[i - 1];

    // h1 = Poseidon(1, prevZero) - domain separator 1 for internal nodes
    const h1 = poseidon([1n, prevZero]);
    const h1Value = F.toObject(h1);

    // result = Poseidon(h1, prevZero)
    const result = poseidon([h1Value, prevZero]);
    computedZeros.push(F.toObject(result));

    const computed = '0x' + computedZeros[i].toString(16).padStart(64, '0');
    const match = computed.toLowerCase() === CONTRACT_ZEROS[i].toLowerCase();

    console.log(`LEVEL ${i} (hashNode(Z${i-1}, Z${i-1})):`);
    console.log(`  Contract: ${CONTRACT_ZEROS[i]}`);
    console.log(`  Computed: ${computed}`);
    console.log(`  Status:   ${match ? 'MATCH' : 'MISMATCH'}`);
    console.log();

    if (!match) {
      mismatches++;
      mismatchDetails.push({ level: i, contract: CONTRACT_ZEROS[i], computed: computed });
    }
  }

  // Initial root: hashNode(zeros[19], zeros[19])
  const lastZero = computedZeros[TREE_DEPTH - 1];
  const rootH1 = poseidon([1n, lastZero]);
  const rootH1Value = F.toObject(rootH1);
  const initialRoot = poseidon([rootH1Value, lastZero]);
  const initialRootValue = F.toObject(initialRoot);

  const computedRoot = '0x' + initialRootValue.toString(16).padStart(64, '0');
  const rootMatch = computedRoot.toLowerCase() === CONTRACT_INITIAL_ROOT.toLowerCase();

  console.log("INITIAL_ROOT (hashNode(Z19, Z19)):");
  console.log(`  Contract: ${CONTRACT_INITIAL_ROOT}`);
  console.log(`  Computed: ${computedRoot}`);
  console.log(`  Status:   ${rootMatch ? 'MATCH' : 'MISMATCH'}`);
  console.log();

  if (!rootMatch) {
    mismatches++;
    mismatchDetails.push({ level: 'INITIAL_ROOT', contract: CONTRACT_INITIAL_ROOT, computed: computedRoot });
  }

  // Summary
  console.log("=".repeat(70));
  console.log("  VERIFICATION SUMMARY");
  console.log("=".repeat(70));
  console.log(`Total checks:  21 (20 levels + 1 initial root)`);
  console.log(`Matches:       ${21 - mismatches}`);
  console.log(`Mismatches:    ${mismatches}`);
  console.log();

  if (mismatches === 0) {
    console.log("VERIFICATION PASSED: All ZERO_HASHES match circomlibjs computation.");
    console.log("The CommitmentTree.sol constants are correct and circuit-compatible.");
    console.log();
    process.exit(0);
  } else {
    console.log("VERIFICATION FAILED: Some values do not match.");
    console.log();
    console.log("MISMATCH DETAILS:");
    for (const detail of mismatchDetails) {
      console.log(`  Level ${detail.level}:`);
      console.log(`    Contract: ${detail.contract}`);
      console.log(`    Expected: ${detail.computed}`);
    }
    console.log();
    console.log("ACTION REQUIRED: Report these mismatches and wait for explicit approval");
    console.log("before making any changes to CommitmentTree.sol");
    console.log();
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("Error during verification:", error);
  process.exit(1);
});
