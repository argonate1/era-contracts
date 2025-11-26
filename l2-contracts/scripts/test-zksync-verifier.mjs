/**
 * Quick test for the new ZKsync-compatible RedeemVerifier
 *
 * This test generates a fresh proof and tests it against both:
 * 1. The original RedeemVerifier (EIP-197 format) - expected to FAIL
 * 2. The new RedeemVerifierZkSync (ZKsync format) - expected to PASS
 */

import { Provider, Wallet, Contract } from 'zksync-ethers';
import { ethers } from 'ethers';
import { poseidon2 } from 'poseidon-lite';
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

let snarkjs;

const __dirname = dirname(fileURLToPath(import.meta.url));

// Configuration
const CONFIG = {
  RPC_URL: 'http://127.0.0.1:3150',
  PRIVATE_KEY: '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c',

  // Verifiers
  OLD_VERIFIER: '0x177529B573cDe3481dD067559043b75672591eDa',  // Original RedeemVerifier
  ZKSYNC_VERIFIER: '0x9D55Db2F7EDa1f40B335dB72CF50F386AD06EfdA',  // New ZKsync-compatible

  // Ghost Token for context
  GHOST_TOKEN: '0x6de3c6DF6A6b29939C3a75f801A2215C45894719',

  // Circuit files
  CIRCUITS_PATH: join(__dirname, '..', '..', '..', 'sdk', 'ghost-ui', 'public', 'circuits'),

  TREE_DEPTH: 20,
};

// Field constants
const FIELD_MODULUS = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');

// Cryptographic utilities
function hexToBigInt(hex) {
  return BigInt(hex);
}

function bigIntToHex(value) {
  return '0x' + value.toString(16).padStart(64, '0');
}

function randomFieldElement() {
  const bytes = ethers.utils.randomBytes(32);
  let value = BigInt('0x' + Buffer.from(bytes).toString('hex'));
  return bigIntToHex(value % FIELD_MODULUS);
}

function poseidon4(a, b, c, d) {
  const h1 = poseidon2([a, b]);
  const h2 = poseidon2([c, d]);
  return poseidon2([h1, h2]);
}

function computeCommitment(secret, nullifier, amount, tokenAddress) {
  const secretBn = hexToBigInt(secret);
  const nullifierBn = hexToBigInt(nullifier);
  const tokenBn = BigInt(tokenAddress);
  const commitment = poseidon4(secretBn, nullifierBn, amount, tokenBn);
  return bigIntToHex(commitment % FIELD_MODULUS);
}

function hashLeaf(value) {
  const hash = poseidon2([0n, hexToBigInt(value)]);
  return bigIntToHex(hash);
}

function hashNode(left, right) {
  const h1 = poseidon2([1n, hexToBigInt(left)]);
  const hash = poseidon2([h1, hexToBigInt(right)]);
  return bigIntToHex(hash);
}

function computeNullifierHash(secret, leafIndex) {
  const hash = poseidon2([hexToBigInt(secret), BigInt(leafIndex)]);
  return bigIntToHex(hash);
}

// Build simple Merkle tree and generate proof
function buildMerkleTree(leaves, depth) {
  const tree = [leaves.map(l => l)];

  for (let level = 0; level < depth; level++) {
    const currentLevel = tree[level];
    const nextLevel = [];

    for (let i = 0; i < currentLevel.length; i += 2) {
      const left = currentLevel[i] || bigIntToHex(0n);
      const right = currentLevel[i + 1] || bigIntToHex(0n);
      nextLevel.push(hashNode(left, right));
    }

    if (nextLevel.length === 0) {
      nextLevel.push(hashNode(bigIntToHex(0n), bigIntToHex(0n)));
    }

    tree.push(nextLevel);
  }

  return tree;
}

function getMerkleProof(tree, leafIndex, depth) {
  const pathElements = [];
  const pathIndices = [];

  let idx = leafIndex;
  for (let level = 0; level < depth; level++) {
    const siblingIdx = idx % 2 === 0 ? idx + 1 : idx - 1;
    pathIndices.push(idx % 2);

    const sibling = tree[level][siblingIdx] || bigIntToHex(0n);
    pathElements.push(sibling);

    idx = Math.floor(idx / 2);
  }

  return { pathElements, pathIndices };
}

async function main() {
  console.log('='.repeat(60));
  console.log('ZKsync Verifier Comparison Test');
  console.log('='.repeat(60));

  // Dynamic import for snarkjs
  snarkjs = await import('snarkjs');

  const provider = new Provider(CONFIG.RPC_URL);
  const wallet = new Wallet(CONFIG.PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);
  console.log('Old Verifier:', CONFIG.OLD_VERIFIER);
  console.log('ZKsync Verifier:', CONFIG.ZKSYNC_VERIFIER);

  // Generate test data
  const amount = ethers.utils.parseEther('10').toBigInt();
  const secret = randomFieldElement();
  const nullifier = randomFieldElement();
  const leafIndex = 0;
  const recipient = wallet.address;

  const commitment = computeCommitment(secret, nullifier, amount, CONFIG.GHOST_TOKEN);
  const leafHash = hashLeaf(commitment);
  const nullifierHash = computeNullifierHash(secret, leafIndex);

  console.log('\n[1] Test Data Generated');
  console.log('  Secret:', secret.slice(0, 20) + '...');
  console.log('  Nullifier:', nullifier.slice(0, 20) + '...');
  console.log('  Commitment:', commitment);
  console.log('  Leaf Hash:', leafHash);
  console.log('  Nullifier Hash:', nullifierHash);

  // Build Merkle tree with single leaf
  const tree = buildMerkleTree([leafHash], CONFIG.TREE_DEPTH);
  const root = tree[CONFIG.TREE_DEPTH][0];
  const { pathElements, pathIndices } = getMerkleProof(tree, leafIndex, CONFIG.TREE_DEPTH);

  console.log('\n[2] Merkle Tree Built');
  console.log('  Root:', root);

  // Prepare circuit input
  const circuitInput = {
    merkleRoot: hexToBigInt(root).toString(),
    nullifier: hexToBigInt(nullifierHash).toString(),
    amount: amount.toString(),
    tokenAddress: BigInt(CONFIG.GHOST_TOKEN).toString(),
    recipient: BigInt(recipient).toString(),
    secret: hexToBigInt(secret).toString(),
    leafIndex: leafIndex.toString(),
    pathElements: pathElements.map(p => hexToBigInt(p).toString()),
    pathIndices: pathIndices.map(i => i.toString()),
  };

  console.log('\n[3] Generating Groth16 Proof...');
  const wasmPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'redeem.wasm');
  const zkeyPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'redeem_final.zkey');

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInput,
    wasmPath,
    zkeyPath
  );

  console.log('  Proof generated!');
  console.log('  Public signals:', publicSignals);

  // Verify locally first
  const vkeyPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'verification_key.json');
  const vkey = JSON.parse(readFileSync(vkeyPath, 'utf8'));
  const localValid = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  console.log('\n[4] Local Verification:', localValid ? '✅ VALID' : '❌ INVALID');

  if (!localValid) {
    console.log('Proof invalid locally, stopping test');
    return;
  }

  // Prepare for on-chain verification
  const VERIFIER_ABI = [
    'function verifyProof(uint256[2] calldata _pA, uint256[2][2] calldata _pB, uint256[2] calldata _pC, uint256[6] calldata _pubSignals) view returns (bool)',
  ];

  const oldVerifier = new Contract(CONFIG.OLD_VERIFIER, VERIFIER_ABI, wallet);
  const zksyncVerifier = new Contract(CONFIG.ZKSYNC_VERIFIER, VERIFIER_ABI, wallet);

  // Proof points
  const pA = [proof.pi_a[0], proof.pi_a[1]];
  const pC = [proof.pi_c[0], proof.pi_c[1]];

  // B coordinates - without swap (for old verifier comparison)
  const pB_noSwap = [
    [proof.pi_b[0][0], proof.pi_b[0][1]],
    [proof.pi_b[1][0], proof.pi_b[1][1]],
  ];

  // B coordinates - with swap (for ZKsync verifier)
  const pB_swapped = [
    [proof.pi_b[0][1], proof.pi_b[0][0]],  // Swap for ZKsync Era
    [proof.pi_b[1][1], proof.pi_b[1][0]],
  ];

  // Public signals array (6 elements as circuit outputs)
  const pubSigs = publicSignals.map(s => s.toString());

  console.log('\n[5] Testing OLD Verifier (no B swap)...');
  try {
    const oldResult = await oldVerifier.verifyProof(pA, pB_noSwap, pC, pubSigs);
    console.log('  Result:', oldResult ? '✅ VALID' : '❌ INVALID');
  } catch (e) {
    console.log('  Error:', e.message.slice(0, 80) + '...');
  }

  console.log('\n[6] Testing OLD Verifier (with B swap)...');
  try {
    const oldSwapResult = await oldVerifier.verifyProof(pA, pB_swapped, pC, pubSigs);
    console.log('  Result:', oldSwapResult ? '✅ VALID' : '❌ INVALID');
  } catch (e) {
    console.log('  Error:', e.message.slice(0, 80) + '...');
  }

  console.log('\n[7] Testing ZKSYNC Verifier (with B swap)...');
  try {
    const zksyncResult = await zksyncVerifier.verifyProof(pA, pB_swapped, pC, pubSigs);
    console.log('  Result:', zksyncResult ? '✅ VALID' : '❌ INVALID');

    if (zksyncResult) {
      console.log('\n' + '='.repeat(60));
      console.log('🎉 SUCCESS! ZKsync Verifier validates the proof!');
      console.log('='.repeat(60));
    }
  } catch (e) {
    console.log('  Error:', e.message.slice(0, 80) + '...');
  }

  console.log('\n[8] Testing ZKSYNC Verifier (no B swap)...');
  try {
    const zksyncNoSwapResult = await zksyncVerifier.verifyProof(pA, pB_noSwap, pC, pubSigs);
    console.log('  Result:', zksyncNoSwapResult ? '✅ VALID' : '❌ INVALID');
  } catch (e) {
    console.log('  Error:', e.message.slice(0, 80) + '...');
  }

  console.log('\n' + '='.repeat(60));
}

main().catch(console.error);
