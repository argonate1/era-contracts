/**
 * Test Poseidon Fix
 *
 * Verifies that the PoseidonT3 memory fix works correctly on EraVM by:
 * 1. Computing hashNode on the contract
 * 2. Computing the same hash in the SDK
 * 3. Comparing results to confirm they match
 */

import { Wallet, Provider, Contract } from "zksync-ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

// SDK Poseidon implementation (matching core.ts)
const { poseidon2 } = require("poseidon-lite");

const PRIVATE_KEY = process.env.WALLET_PRIVATE_KEY || "0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5";
const RPC_URL = process.env.ZKSYNC_RPC_URL || "http://127.0.0.1:3050";

// SDK hash functions (must match core.ts exactly)
function hashLeaf(value: bigint): bigint {
  return poseidon2([BigInt(0), value]); // Domain separator 0 for leaves
}

function hashNode(left: bigint, right: bigint): bigint {
  const h1 = poseidon2([BigInt(1), left]); // Domain separator 1 for nodes
  return poseidon2([h1, right]);
}

async function loadDeployment(): Promise<{commitmentTree: string}> {
  const deploymentPath = path.join(__dirname, "../deployments/ghost-production-271.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error(`Deployment file not found: ${deploymentPath}`);
  }
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
  return {
    commitmentTree: deployment.contracts.commitmentTree
  };
}

async function main() {
  console.log("=".repeat(60));
  console.log("Poseidon Fix Verification Test");
  console.log("=".repeat(60));

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const { commitmentTree } = await loadDeployment();

  console.log(`\nCommitmentTree: ${commitmentTree}`);

  // CommitmentTree ABI with test functions
  const treeABI = [
    "function computeHashNode(bytes32 left, bytes32 right) external pure returns (bytes32)",
    "function root() external view returns (bytes32)",
    "function nextLeafIndex() external view returns (uint256)"
  ];

  const tree = new Contract(commitmentTree, treeABI, wallet);

  // Test values
  const testLeft = BigInt("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
  const testRight = BigInt("0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321");

  console.log("\n--- Test 1: hashNode verification ---");
  console.log(`Left:  ${testLeft.toString(16).padStart(64, '0')}`);
  console.log(`Right: ${testRight.toString(16).padStart(64, '0')}`);

  // Compute on contract
  const leftBytes = "0x" + testLeft.toString(16).padStart(64, '0');
  const rightBytes = "0x" + testRight.toString(16).padStart(64, '0');

  let contractHash: string;
  try {
    contractHash = await tree.computeHashNode(leftBytes, rightBytes);
    console.log(`\nContract hashNode: ${contractHash}`);
  } catch (error: any) {
    console.error(`Contract call failed: ${error.message}`);
    process.exit(1);
  }

  // Compute in SDK
  const sdkHash = hashNode(testLeft, testRight);
  const sdkHashHex = "0x" + sdkHash.toString(16).padStart(64, '0');
  console.log(`SDK hashNode:      ${sdkHashHex}`);

  // Compare
  const hashMatch = contractHash.toLowerCase() === sdkHashHex.toLowerCase();
  console.log(`\nHash Match: ${hashMatch ? '✅ YES' : '❌ NO'}`);

  if (!hashMatch) {
    console.log("\n❌ POSEIDON FIX VERIFICATION FAILED!");
    console.log("The contract hashNode does not match SDK hashNode.");
    console.log("This means the PoseidonT3 memory fix is not working correctly.");
    process.exit(1);
  }

  // Test 2: Check that hashNode is NOT returning just the left input
  // (This was the bug - hashNode was returning left instead of the actual hash)
  console.log("\n--- Test 2: Verify hashNode is not passthrough ---");
  const leftHex = leftBytes.toLowerCase();
  const isPassthrough = contractHash.toLowerCase() === leftHex;
  console.log(`Contract result equals left input: ${isPassthrough ? '❌ YES (BUG!)' : '✅ NO (correct)'}`);

  if (isPassthrough) {
    console.log("\n❌ BUG DETECTED: hashNode is returning the left input unchanged!");
    console.log("The Poseidon fix did not work.");
    process.exit(1);
  }

  // Test 3: Verify multiple hashNode calls work correctly
  console.log("\n--- Test 3: Multiple sequential hashNode calls ---");
  const zero = BigInt(0);
  const one = BigInt(1);
  const two = BigInt(2);

  const zeroBytes = "0x" + zero.toString(16).padStart(64, '0');
  const oneBytes = "0x" + one.toString(16).padStart(64, '0');
  const twoBytes = "0x" + two.toString(16).padStart(64, '0');

  const hash1Contract = await tree.computeHashNode(zeroBytes, oneBytes);
  const hash2Contract = await tree.computeHashNode(oneBytes, twoBytes);
  const hash3Contract = await tree.computeHashNode(hash1Contract, hash2Contract);

  const hash1SDK = hashNode(zero, one);
  const hash2SDK = hashNode(one, two);
  const hash3SDK = hashNode(hash1SDK, hash2SDK);

  const hash1Match = hash1Contract.toLowerCase() === ("0x" + hash1SDK.toString(16).padStart(64, '0')).toLowerCase();
  const hash2Match = hash2Contract.toLowerCase() === ("0x" + hash2SDK.toString(16).padStart(64, '0')).toLowerCase();
  const hash3Match = hash3Contract.toLowerCase() === ("0x" + hash3SDK.toString(16).padStart(64, '0')).toLowerCase();

  console.log(`Hash(0, 1) match: ${hash1Match ? '✅' : '❌'}`);
  console.log(`Hash(1, 2) match: ${hash2Match ? '✅' : '❌'}`);
  console.log(`Hash(Hash(0,1), Hash(1,2)) match: ${hash3Match ? '✅' : '❌'}`);

  // Test 4: Check current tree state
  console.log("\n--- Test 4: Current tree state ---");
  const currentRoot = await tree.root();
  const nextLeafIndex = await tree.nextLeafIndex();
  console.log(`Current root: ${currentRoot}`);
  console.log(`Next leaf index: ${nextLeafIndex.toString()}`);

  // Success summary
  console.log("\n" + "=".repeat(60));
  if (hashMatch && !isPassthrough && hash1Match && hash2Match && hash3Match) {
    console.log("✅ ALL POSEIDON TESTS PASSED!");
    console.log("The PoseidonT3 memory fix is working correctly on EraVM.");
    console.log("\nThe SDK and contract Merkle trees should now stay in sync.");
    console.log("You can test the full ghost/redeem flow in the UI.");
  } else {
    console.log("❌ POSEIDON TESTS FAILED!");
    process.exit(1);
  }
  console.log("=".repeat(60));
}

main().catch((error) => {
  console.error("\nError:", error.message);
  process.exit(1);
});
