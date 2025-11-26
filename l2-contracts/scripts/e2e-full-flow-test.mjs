/**
 * Full E2E Test: Ghost → Redeem with Working Verifier
 *
 * Tests the complete flow with proper Merkle tree construction
 * matching the circuit's expected hash functions.
 * Relies on relayer to submit Merkle roots.
 */

import { Provider, Wallet, Contract } from 'zksync-ethers';
import { ethers } from 'ethers';
import { poseidon2 } from 'poseidon-lite';
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

let snarkjs;
const __dirname = dirname(fileURLToPath(import.meta.url));

// Configuration with v4 token that uses working verifier
const CONFIG = {
  RPC_URL: 'http://127.0.0.1:3150',
  PRIVATE_KEY: '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c',

  // Token v5 with ZKsync-compatible RedeemVerifierWorking
  GHOST_TOKEN: '0x2a1aaee151070ea12B69044bfFEF51E3FE12048A',

  // CORRECT infrastructure addresses
  COMMITMENT_TREE: '0x456e224ADe45E4C4809F89D03C92Df65165f86CA',
  NULLIFIER_REGISTRY: '0xbFaF8231ED01e2631AfFE7F5e3c6d85006B8b33F',

  // NEW verifier proxy with RedeemVerifierWorking (bytes memory pattern)
  VERIFIER_PROXY: '0xFc5a8C6bf0D4c85f3d25dFcAF955Dc8Af1b04Db3',

  // Circuit files
  CIRCUITS_PATH: join(__dirname, '..', '..', '..', 'sdk', 'ghost-ui', 'public', 'circuits'),

  TREE_DEPTH: 20,
  GHOST_AMOUNT: ethers.utils.parseEther('10'),
};

// Field constants
const FIELD_MODULUS = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');

// Contract ABIs
const GHOST_TOKEN_ABI = [
  'function ghost(uint256 amount, bytes32 commitment) external returns (uint256 leafIndex)',
  'function redeem(uint256 amount, address recipient, bytes32 nullifier, bytes32 merkleRoot, bytes32[] calldata merkleProof, uint256[] calldata pathIndices, bytes calldata zkProof) external',
  'function balanceOf(address) view returns (uint256)',
  'function bridgeMint(address to, uint256 amount) external',
  'function verifier() view returns (address)',
  'function commitmentTree() view returns (address)',
  'event Ghosted(address indexed sender, uint256 amount, bytes32 indexed commitment, uint256 indexed leafIndex)',
  'event Redeemed(uint256 amount, address indexed recipient, bytes32 indexed nullifier)',
];

const COMMITMENT_TREE_ABI = [
  'function getRoot() view returns (bytes32)',
  'function isKnownRoot(bytes32 root) view returns (bool)',
  'function getNextLeafIndex() view returns (uint256)',
  'function submitRoot(bytes32 newRoot, uint256 leafCount) external',
  'function getCommitment(uint256 index) view returns (bytes32)',
  'function getCommitmentCount() view returns (uint256)',
];

// ============================================================================
// Crypto utilities matching the relayer exactly
// ============================================================================

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

/**
 * Poseidon hash with 4 inputs using tree structure
 */
function poseidon4(a, b, c, d) {
  const h1 = poseidon2([a, b]);
  const h2 = poseidon2([c, d]);
  return poseidon2([h1, h2]);
}

/**
 * Compute commitment
 */
function computeCommitment(secret, nullifier, amount, tokenAddress) {
  const secretBn = hexToBigInt(secret);
  const nullifierBn = hexToBigInt(nullifier);
  const tokenBn = BigInt(tokenAddress);
  const commitment = poseidon4(secretBn, nullifierBn, amount, tokenBn);
  return bigIntToHex(commitment % FIELD_MODULUS);
}

// Domain-separated hashing (matches relayer exactly)
function hashLeaf(value) {
  const hash = poseidon2([0n, hexToBigInt(value)]);
  return bigIntToHex(hash);
}

function hashNode(left, right) {
  const h1 = poseidon2([1n, hexToBigInt(left)]);
  const hash = poseidon2([h1, hexToBigInt(right)]);
  return bigIntToHex(hash);
}

/**
 * Compute nullifier hash
 */
function computeNullifierHash(secret, leafIndex) {
  const hash = poseidon2([hexToBigInt(secret), BigInt(leafIndex)]);
  return bigIntToHex(hash);
}

// ============================================================================
// MerkleTree class (matches relayer exactly)
// ============================================================================

class MerkleTree {
  constructor(depth = CONFIG.TREE_DEPTH) {
    this.depth = depth;
    this.levels = Array.from({ length: depth + 1 }, () => new Map());
    this.zeroValues = this.computeZeroValues();
    this.nextIndex = 0;
  }

  computeZeroValues() {
    const zeros = [];
    let current = hashLeaf('0x' + '0'.repeat(64));
    zeros[0] = current;

    for (let i = 1; i <= this.depth; i++) {
      current = hashNode(current, current);
      zeros[i] = current;
    }
    return zeros;
  }

  insert(commitment) {
    const leafIndex = this.nextIndex;
    const leafHash = hashLeaf(commitment);
    this.levels[0].set(leafIndex, leafHash);

    let currentIndex = leafIndex;
    let currentHash = leafHash;

    for (let level = 0; level < this.depth; level++) {
      const isRight = currentIndex % 2 === 1;
      const siblingIndex = isRight ? currentIndex - 1 : currentIndex + 1;
      const sibling = this.levels[level].get(siblingIndex) ?? this.zeroValues[level];

      const [left, right] = isRight ? [sibling, currentHash] : [currentHash, sibling];
      currentHash = hashNode(left, right);
      currentIndex = Math.floor(currentIndex / 2);
      this.levels[level + 1].set(currentIndex, currentHash);
    }

    this.nextIndex++;
    return leafIndex;
  }

  getRoot() {
    return this.levels[this.depth].get(0) ?? this.zeroValues[this.depth];
  }

  getProof(leafIndex) {
    const pathElements = [];
    const pathIndices = [];
    let currentIndex = leafIndex;

    for (let level = 0; level < this.depth; level++) {
      const isRight = currentIndex % 2 === 1;
      const siblingIndex = isRight ? currentIndex - 1 : currentIndex + 1;
      const sibling = this.levels[level].get(siblingIndex) ?? this.zeroValues[level];

      pathElements.push(sibling);
      pathIndices.push(isRight ? 1 : 0);
      currentIndex = Math.floor(currentIndex / 2);
    }

    return { pathElements, pathIndices, root: this.getRoot() };
  }
}

// Helper to wait with timeout
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function main() {
  console.log('='.repeat(70));
  console.log('Full E2E Test: Ghost → Redeem with Working Verifier');
  console.log('='.repeat(70));

  snarkjs = await import('snarkjs');

  const provider = new Provider(CONFIG.RPC_URL);
  const wallet = new Wallet(CONFIG.PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);
  console.log('Ghost Token:', CONFIG.GHOST_TOKEN);
  console.log('Verifier Proxy:', CONFIG.VERIFIER_PROXY);

  const ghostToken = new Contract(CONFIG.GHOST_TOKEN, GHOST_TOKEN_ABI, wallet);
  const commitmentTree = new Contract(CONFIG.COMMITMENT_TREE, COMMITMENT_TREE_ABI, wallet);

  // Check setup
  const verifier = await ghostToken.verifier();
  console.log('\n[0] Token verifier address:', verifier);
  if (verifier.toLowerCase() !== CONFIG.VERIFIER_PROXY.toLowerCase()) {
    console.log('WARNING: Verifier mismatch!');
  }

  // Check balance
  const balance = await ghostToken.balanceOf(wallet.address);
  console.log('Current balance:', ethers.utils.formatEther(balance), 'tokens');

  if (balance.lt(CONFIG.GHOST_AMOUNT)) {
    console.log('Insufficient balance - minting tokens via bridgeMint...');
    const mintAmount = CONFIG.GHOST_AMOUNT;
    const mintTx = await ghostToken.bridgeMint(wallet.address, mintAmount, { gasLimit: 1000000 });
    await mintTx.wait();
    const newBalance = await ghostToken.balanceOf(wallet.address);
    console.log('New balance after mint:', ethers.utils.formatEther(newBalance), 'tokens');
  }

  // =========================================================================
  // IMPORTANT: The circuit constrains nullifier = Poseidon2(secret, leafIndex)
  // So we must:
  //   1. Get the expected leafIndex BEFORE ghosting
  //   2. Compute nullifier = Poseidon2(secret, leafIndex)
  //   3. Compute commitment = poseidon4(secret, nullifier, amount, token)
  //   4. Ghost with that commitment
  // =========================================================================

  // Get expected leaf index (next available slot)
  const expectedLeafIndex = await commitmentTree.getNextLeafIndex();
  console.log('\n[1] Preparing Ghost Commitment');
  console.log('  Expected leaf index:', expectedLeafIndex.toString());

  // Generate secret and compute deterministic nullifier
  const amount = CONFIG.GHOST_AMOUNT.toBigInt();
  const secret = randomFieldElement();

  // CRITICAL: nullifier = Poseidon2(secret, leafIndex) - deterministically derived!
  const leafIndexNum = expectedLeafIndex.toNumber();
  const nullifier = computeNullifierHash(secret, leafIndexNum);  // This IS the nullifier for commitment

  console.log('  Amount:', ethers.utils.formatEther(CONFIG.GHOST_AMOUNT), 'tokens');
  console.log('  Secret:', secret.slice(0, 20) + '...');
  console.log('  Nullifier (derived from secret + leafIndex):', nullifier.slice(0, 20) + '...');

  // Compute commitment using the derived nullifier
  const commitment = computeCommitment(secret, nullifier, amount, CONFIG.GHOST_TOKEN);
  console.log('  Commitment:', commitment);

  // Ghost the tokens
  console.log('\n[2] Ghosting Tokens...');
  const ghostTx = await ghostToken.ghost(CONFIG.GHOST_AMOUNT, commitment);
  const ghostReceipt = await ghostTx.wait();

  // Verify leaf index matches what we expected
  const ghostEvent = ghostReceipt.events?.find(e => e.event === 'Ghosted');
  let actualLeafIndex;
  if (ghostEvent) {
    actualLeafIndex = ghostEvent.args.leafIndex.toNumber();
  } else {
    const count = await commitmentTree.getCommitmentCount();
    actualLeafIndex = count.toNumber() - 1;
  }

  console.log('  Ghost successful! Leaf index:', actualLeafIndex);

  // CRITICAL: Verify leaf index matches expected
  if (actualLeafIndex !== leafIndexNum) {
    console.log('\n❌ ERROR: Leaf index mismatch!');
    console.log('  Expected:', leafIndexNum);
    console.log('  Actual:', actualLeafIndex);
    console.log('  This commitment cannot be redeemed (nullifier is bound to wrong leafIndex)');
    return;
  }
  console.log('  ✅ Leaf index matches expected - commitment is valid');

  // Wait for relayer to submit root (poll for up to 30 seconds)
  console.log('\n[3] Waiting for relayer to submit root...');
  let rootFound = false;
  let attempts = 0;
  const maxAttempts = 30;

  // Build our local tree to know what root to expect
  const tree = new MerkleTree();
  const commitmentCount = await commitmentTree.getCommitmentCount();
  console.log('  Total commitments:', commitmentCount.toString());

  for (let i = 0; i < commitmentCount.toNumber(); i++) {
    const comm = await commitmentTree.getCommitment(i);
    tree.insert(comm);
  }

  const expectedRoot = tree.getRoot();
  console.log('  Expected root:', expectedRoot);

  // Poll until root is found
  while (!rootFound && attempts < maxAttempts) {
    const isKnown = await commitmentTree.isKnownRoot(expectedRoot);
    if (isKnown) {
      rootFound = true;
      console.log('  Root is now known! (attempt', attempts + 1 + ')');
    } else {
      await sleep(1000);
      attempts++;
      if (attempts % 5 === 0) {
        console.log('  Still waiting... (attempt', attempts + ')');
      }
    }
  }

  if (!rootFound) {
    // Try to submit root ourselves if relayer didn't
    console.log('  Root not found - attempting to submit ourselves...');
    try {
      const submitTx = await commitmentTree.submitRoot(expectedRoot, commitmentCount);
      await submitTx.wait();
      console.log('  Root submitted successfully!');
      rootFound = true;
    } catch (e) {
      console.log('  Submit failed:', e.message.slice(0, 100));
      // Check if it's already there
      const isKnown = await commitmentTree.isKnownRoot(expectedRoot);
      if (isKnown) {
        rootFound = true;
        console.log('  Root was already submitted!');
      }
    }
  }

  if (!rootFound) {
    console.log('\nERROR: Could not get root into contract!');
    return;
  }

  // Get Merkle proof
  console.log('\n[4] Generating Merkle Proof...');
  const proof = tree.getProof(leafIndexNum);
  console.log('  Root:', proof.root);
  console.log('  Path elements (first 3):', proof.pathElements.slice(0, 3).map(p => p.slice(0, 18) + '...'));

  // The nullifier is already computed as Poseidon2(secret, leafIndex) and stored in `nullifier` variable
  // This same value was used in the commitment and is used as the public input
  console.log('  Nullifier (public input):', nullifier.slice(0, 20) + '...');

  // Generate ZK proof
  // The circuit's public `nullifier` input is Poseidon2(secret, leafIndex)
  // This is the SAME value we used in the commitment computation (stored in `nullifier` variable)
  // The circuit verifies: nullifier == Poseidon2(secret, leafIndex)
  console.log('\n[5] Generating ZK Proof...');
  const circuitInput = {
    merkleRoot: hexToBigInt(proof.root).toString(),
    nullifier: hexToBigInt(nullifier).toString(),  // = Poseidon2(secret, leafIndex)
    amount: amount.toString(),
    tokenAddress: BigInt(CONFIG.GHOST_TOKEN).toString(),
    recipient: BigInt(wallet.address).toString(),
    secret: hexToBigInt(secret).toString(),
    leafIndex: leafIndexNum.toString(),
    pathElements: proof.pathElements.map(p => hexToBigInt(p).toString()),
    pathIndices: proof.pathIndices.map(i => i.toString()),
  };

  console.log('  Circuit inputs:');
  console.log('    merkleRoot:', circuitInput.merkleRoot.slice(0, 20) + '...');
  console.log('    nullifier:', circuitInput.nullifier.slice(0, 20) + '...');
  console.log('    amount:', circuitInput.amount);
  console.log('    leafIndex:', circuitInput.leafIndex);

  const wasmPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'redeem.wasm');
  const zkeyPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'redeem_final.zkey');

  const { proof: zkProofData, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInput,
    wasmPath,
    zkeyPath
  );

  console.log('  Proof generated!');
  console.log('  Public signals:', publicSignals.slice(0, 3).map(s => s.slice(0, 20) + '...'));

  // Verify locally
  const vkeyPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'verification_key.json');
  const vkey = JSON.parse(readFileSync(vkeyPath, 'utf8'));
  const localValid = await snarkjs.groth16.verify(vkey, publicSignals, zkProofData);
  console.log('  Local verification:', localValid ? '✅ VALID' : '❌ INVALID');

  if (!localValid) {
    console.log('\nERROR: Proof invalid locally!');
    return;
  }

  // Prepare proof for contract (with B coordinate swap for ZKsync)
  console.log('\n[6] Preparing Proof for Contract...');

  const pA = [zkProofData.pi_a[0], zkProofData.pi_a[1]];
  const pB = [
    [zkProofData.pi_b[0][1], zkProofData.pi_b[0][0]],  // Swap for ZKsync (imaginary, real)
    [zkProofData.pi_b[1][1], zkProofData.pi_b[1][0]],
  ];
  const pC = [zkProofData.pi_c[0], zkProofData.pi_c[1]];

  // Encode proof with commitment output (first public signal)
  const commitmentOut = publicSignals[0];
  const zkProof = ethers.utils.defaultAbiCoder.encode(
    ['uint256[2]', 'uint256[2][2]', 'uint256[2]', 'uint256'],
    [pA, pB, pC, commitmentOut]
  );

  console.log('  Proof encoded for contract');
  console.log('  CommitmentOut:', commitmentOut.slice(0, 20) + '...');

  // Call redeem
  console.log('\n[7] Calling Redeem...');
  const recipient = wallet.address;

  console.log('  Using root:', proof.root);
  console.log('  Recipient:', recipient);

  try {
    const balanceBefore = await ghostToken.balanceOf(wallet.address);
    console.log('  Balance before redeem:', ethers.utils.formatEther(balanceBefore));

    const redeemTx = await ghostToken.redeem(
      CONFIG.GHOST_AMOUNT,
      recipient,
      nullifier,  // = Poseidon2(secret, leafIndex), used to mark as spent
      proof.root,
      proof.pathElements,
      proof.pathIndices,
      zkProof,
      { gasLimit: 50000000 }
    );

    console.log('  Transaction hash:', redeemTx.hash);
    console.log('  Waiting for confirmation...');
    const redeemReceipt = await redeemTx.wait();

    const balanceAfter = await ghostToken.balanceOf(wallet.address);
    console.log('  Balance after redeem:', ethers.utils.formatEther(balanceAfter));

    console.log('\n' + '='.repeat(70));
    console.log('SUCCESS! FULL E2E FLOW COMPLETED!');
    console.log('='.repeat(70));
    console.log('  Ghost: ✅');
    console.log('  Merkle Tree Build: ✅');
    console.log('  Root Available: ✅');
    console.log('  ZK Proof Generation: ✅');
    console.log('  Local Verification: ✅');
    console.log('  On-chain Verification: ✅');
    console.log('  Redemption: ✅');
    console.log('='.repeat(70));

  } catch (e) {
    console.log('\n❌ Redeem failed:', e.message);
    if (e.message.includes('InvalidProof')) {
      console.log('  The proof verification failed on-chain.');
    }
    if (e.message.includes('InvalidRoot')) {
      console.log('  The merkle root is not recognized.');
    }
    if (e.message.includes('NullifierAlreadySpent')) {
      console.log('  The nullifier has already been used.');
    }
  }
}

main().catch(console.error);
