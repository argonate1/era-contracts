/**
 * E2E Test for Groth16 ZK Verifier
 *
 * Tests the full ghost → redeem flow with real Groth16 proofs.
 */

import { Provider, Wallet, Contract, utils as zkUtils } from 'zksync-ethers';
import { ethers } from 'ethers';
import { poseidon2 } from 'poseidon-lite';
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

// We'll use dynamic import for snarkjs since it's a CommonJS module
let snarkjs;

const __dirname = dirname(fileURLToPath(import.meta.url));

// Configuration
const CONFIG = {
  RPC_URL: 'http://127.0.0.1:3150',
  PRIVATE_KEY: '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c',
  CHAIN_ID: 5447,

  // Deployed contracts
  GHOST_TOKEN: '0x6de3c6DF6A6b29939C3a75f801A2215C45894719',
  COMMITMENT_TREE: '0x456e224ADe45E4C4809F89D03C92Df65165f86CA',
  NULLIFIER_REGISTRY: '0xbFaF8231ED01e2631AfFE7F5e3c6d85006B8b33F',
  VERIFIER_PROXY: '0x3D6b358c2A0b25BDf546C178950D1B0e110c9b5f',

  // Circuit files
  CIRCUITS_PATH: join(__dirname, '..', '..', '..', 'sdk', 'ghost-ui', 'public', 'circuits'),

  TREE_DEPTH: 20,
  GHOST_AMOUNT: ethers.utils.parseEther('10'), // 10 tokens
};

// Field constants
const FIELD_MODULUS = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617');

// Contract ABIs (minimal)
const GHOST_TOKEN_ABI = [
  'function ghost(uint256 amount, bytes32 commitment) external returns (uint256 leafIndex)',
  'function redeem(uint256 amount, address recipient, bytes32 nullifier, bytes32 merkleRoot, bytes32[] calldata merkleProof, uint256[] calldata pathIndices, bytes calldata zkProof) external',
  'function balanceOf(address) view returns (uint256)',
  'function approve(address spender, uint256 amount) external returns (bool)',
  'function bridgeMint(address to, uint256 amount) external',
  'event Ghosted(address indexed sender, uint256 amount, bytes32 indexed commitment, uint256 indexed leafIndex)',
  'event Redeemed(uint256 amount, address indexed recipient, bytes32 indexed nullifier)',
];

const COMMITMENT_TREE_ABI = [
  'function getRoot() view returns (bytes32)',
  'function getNextLeafIndex() view returns (uint256)',
  'event CommitmentInserted(bytes32 indexed commitment, uint256 indexed leafIndex, bytes32 newRoot)',
];

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

// Merkle tree implementation
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

    return { pathElements, pathIndices };
  }

  getRoot() {
    return this.levels[this.depth].get(0) ?? this.zeroValues[this.depth];
  }
}

// Proof encoding for Solidity
function encodeRedeemProof(proof, publicSignals) {
  const abiCoder = new ethers.utils.AbiCoder();

  const pA = [proof.pi_a[0], proof.pi_a[1]];
  // ZKsync Era precompile requires swapped B coordinates (imaginary, real) order
  // This differs from Ethereum mainnet's EIP-197 (real, imaginary) order
  const pB = [
    [proof.pi_b[0][1], proof.pi_b[0][0]], // Swap for ZKsync Era
    [proof.pi_b[1][1], proof.pi_b[1][0]],
  ];
  const pC = [proof.pi_c[0], proof.pi_c[1]];
  const commitmentOut = publicSignals[0];

  return abiCoder.encode(
    ['uint256[2]', 'uint256[2][2]', 'uint256[2]', 'uint256'],
    [pA, pB, pC, commitmentOut]
  );
}

async function main() {
  console.log('='.repeat(60));
  console.log('Ghost Protocol E2E Test - Groth16 ZK Verification');
  console.log('='.repeat(60));

  // Load snarkjs
  snarkjs = await import('snarkjs');

  const provider = new Provider(CONFIG.RPC_URL);
  const wallet = new Wallet(CONFIG.PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);
  console.log('Ghost Token:', CONFIG.GHOST_TOKEN);
  console.log('Verifier Proxy:', CONFIG.VERIFIER_PROXY);

  // Connect to contracts
  const ghostToken = new Contract(CONFIG.GHOST_TOKEN, GHOST_TOKEN_ABI, wallet);
  const commitmentTree = new Contract(CONFIG.COMMITMENT_TREE, COMMITMENT_TREE_ABI, wallet);

  // Check initial balance
  const initialBalance = await ghostToken.balanceOf(wallet.address);
  console.log('\nInitial token balance:', ethers.utils.formatEther(initialBalance), 'gTEST');

  // === Step 1: Generate secrets and commitment ===
  console.log('\n[Step 1] Generating commitment...');

  // CRITICAL: The circuit computes commitment = Poseidon4(secret, nullifierHash, amount, token)
  // where nullifierHash = Poseidon2(secret, leafIndex)
  // So we need to pre-determine leafIndex by querying current getNextLeafIndex
  const currentNextIndex = await commitmentTree.getNextLeafIndex();
  const predictedLeafIndex = Number(currentNextIndex);
  console.log('Predicted leaf index:', predictedLeafIndex);

  const secret = randomFieldElement();
  const amount = CONFIG.GHOST_AMOUNT;
  const tokenAddress = CONFIG.GHOST_TOKEN;

  // Compute nullifier hash using predicted leaf index
  // This is what the circuit expects: nullifier = Poseidon2(secret, leafIndex)
  const nullifierHash = computeNullifierHash(secret, predictedLeafIndex);
  console.log('Pre-computed nullifier hash:', nullifierHash.slice(0, 18) + '...');

  // Compute commitment using nullifierHash (not a random nullifier)
  // The circuit computes: commitment = Poseidon4(secret, nullifier, amount, token)
  // where "nullifier" is the nullifierHash (the public input)
  const commitment = computeCommitment(secret, nullifierHash, amount, tokenAddress);
  console.log('Secret:', secret.slice(0, 18) + '...');
  console.log('Commitment:', commitment);
  console.log('Amount:', ethers.utils.formatEther(amount), 'gTEST');

  // === Step 2: Ghost tokens ===
  console.log('\n[Step 2] Ghosting tokens...');

  // Approve first
  const approveTx = await ghostToken.approve(CONFIG.GHOST_TOKEN, amount);
  await approveTx.wait();
  console.log('Approved');

  const ghostTx = await ghostToken.ghost(amount, commitment);
  const ghostReceipt = await ghostTx.wait();
  console.log('Ghost TX:', ghostTx.hash);

  // Get leaf index from event
  let leafIndex;
  for (const log of ghostReceipt.logs) {
    try {
      const parsed = commitmentTree.interface.parseLog({
        topics: log.topics,
        data: log.data,
      });
      if (parsed && parsed.name === 'CommitmentInserted') {
        leafIndex = Number(parsed.args[1]);
        console.log('Leaf index:', leafIndex);
        break;
      }
    } catch {}
  }

  if (leafIndex === undefined) {
    throw new Error('Could not find CommitmentInserted event');
  }

  // Verify our prediction was correct (critical for protocol security)
  if (leafIndex !== predictedLeafIndex) {
    throw new Error(`Leaf index mismatch! Predicted ${predictedLeafIndex} but got ${leafIndex}. This could happen due to a race condition.`);
  }
  console.log('Leaf index matches prediction!');

  // === Step 3: Wait for relayer to submit root ===
  console.log('\n[Step 3] Waiting for relayer to submit root...');
  await new Promise(resolve => setTimeout(resolve, 5000));

  const contractRoot = await commitmentTree.getRoot();
  console.log('Contract Merkle root:', contractRoot);

  // === Step 4: Build local Merkle tree ===
  console.log('\n[Step 4] Building local Merkle tree...');

  // Fetch all commitments
  const filter = commitmentTree.filters.CommitmentInserted();
  const events = await commitmentTree.queryFilter(filter, 0, 'latest');

  const tree = new MerkleTree();
  const sortedEvents = events.sort((a, b) => Number(a.args[1]) - Number(b.args[1]));

  for (const event of sortedEvents) {
    tree.insert(event.args[0]);
  }

  const localRoot = tree.getRoot();
  console.log('Local Merkle root:', localRoot);

  if (localRoot !== contractRoot) {
    console.log('WARNING: Local root does not match contract root');
    console.log('This may be because the relayer has not yet submitted the root');
    // Use the local root for now
  }

  // Get Merkle proof
  const { pathElements, pathIndices } = tree.getProof(leafIndex);

  // === Step 5: Generate Groth16 proof ===
  console.log('\n[Step 5] Generating Groth16 ZK proof...');

  // Use the pre-computed nullifier hash (already computed at step 1 using predictedLeafIndex)
  console.log('Using pre-computed nullifier hash:', nullifierHash);

  // Prepare circuit inputs (matching core.ts RedeemCircuitInput)
  // Note: The circuit internally computes nullifier = Poseidon2(secret, leafIndex)
  // and verifies it matches the public nullifier input
  const circuitInput = {
    // Public inputs
    merkleRoot: hexToBigInt(localRoot).toString(),
    nullifier: hexToBigInt(nullifierHash).toString(),
    amount: amount.toString(),
    tokenAddress: BigInt(tokenAddress).toString(),
    recipient: BigInt(wallet.address).toString(),

    // Private inputs
    secret: hexToBigInt(secret).toString(),
    leafIndex: leafIndex.toString(),
    pathElements: pathElements.map(e => hexToBigInt(e).toString()),
    pathIndices: pathIndices.map(i => i.toString()),
  };

  console.log('Circuit input prepared');

  // Load circuit files (use the new circuits in redeem/ subdirectory with leafIndex support)
  const wasmPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'redeem.wasm');
  const zkeyPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'redeem_final.zkey');

  console.log('Loading circuit files...');
  console.log('WASM:', wasmPath);
  console.log('zkey:', zkeyPath);

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInput,
    wasmPath,
    zkeyPath
  );

  console.log('Proof generated!');
  console.log('Public signals:', publicSignals);

  // Verify proof locally first
  console.log('\nVerifying proof locally...');
  const vkeyPath = join(CONFIG.CIRCUITS_PATH, 'redeem', 'verification_key.json');
  let vkey;
  try {
    const vkeyContent = readFileSync(vkeyPath, 'utf-8');
    vkey = JSON.parse(vkeyContent);
  } catch (e) {
    // Generate vkey from zkey if not found
    console.log('Exporting verification key from zkey...');
    vkey = await snarkjs.zKey.exportVerificationKey(zkeyPath);
  }
  const localVerifyResult = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  console.log('Local proof verification:', localVerifyResult ? 'VALID' : 'INVALID');
  if (!localVerifyResult) {
    throw new Error('Proof failed local verification - not submitting to chain');
  }

  // Encode proof for Solidity
  const proofBytes = encodeRedeemProof(proof, publicSignals);
  console.log('Proof encoded for Solidity');

  // === Step 6: Redeem with real ZK proof ===
  console.log('\n[Step 6] Redeeming with Groth16 proof...');

  // Convert Merkle proof to bytes32 array format for contract
  const merkleProofBytes32 = pathElements.map(e => e);  // Already hex strings
  const pathIndicesUint = pathIndices.map(i => i);  // Already integers

  console.log('Calling redeem with:');
  console.log('  amount:', ethers.utils.formatEther(amount), 'gTEST');
  console.log('  recipient:', wallet.address);
  console.log('  nullifier:', nullifierHash.slice(0, 18) + '...');
  console.log('  merkleRoot:', localRoot.slice(0, 18) + '...');
  console.log('  merkleProof length:', merkleProofBytes32.length);
  console.log('  pathIndices length:', pathIndicesUint.length);
  console.log('  zkProof length:', proofBytes.length);

  // === Debug: Check preconditions ===
  console.log('\n[Debug] Checking preconditions...');

  // Check if root is known
  const commitmentTreeDebugAbi = [
    'function isKnownRoot(bytes32 root) view returns (bool)',
    'function getRoot() view returns (bytes32)',
  ];
  const commitmentTreeDebug = new Contract(CONFIG.COMMITMENT_TREE, commitmentTreeDebugAbi, wallet);
  const currentRoot = await commitmentTreeDebug.getRoot();
  console.log('Current contract root:', currentRoot);
  console.log('Root we are using:', localRoot);
  const isKnownRoot = await commitmentTreeDebug.isKnownRoot(localRoot);
  console.log('Is known root:', isKnownRoot);

  // Check if nullifier is spent
  const nullifierRegistryDebugAbi = [
    'function isSpent(bytes32 nullifier) view returns (bool)',
  ];
  const nullifierRegistryDebug = new Contract(CONFIG.NULLIFIER_REGISTRY, nullifierRegistryDebugAbi, wallet);
  const isSpent = await nullifierRegistryDebug.isSpent(nullifierHash);
  console.log('Nullifier already spent:', isSpent);

  // Try to directly call verifier proxy
  console.log('\n[Debug] Testing verifier proxy directly...');
  const verifierProxyAbi = [
    'function verifyRedemptionProof(bytes calldata proof, uint256[] calldata publicInputs) view returns (bool)',
    'function redeemVerifier() view returns (address)',
  ];
  const verifierProxy = new Contract(CONFIG.VERIFIER_PROXY, verifierProxyAbi, wallet);

  // Get the verifier address
  const redeemVerifierAddr = await verifierProxy.redeemVerifier();
  console.log('RedeemVerifier address:', redeemVerifierAddr);

  // Build publicInputs as contract would
  const debugPublicInputs = [
    BigInt(localRoot).toString(),          // merkleRoot
    BigInt(nullifierHash).toString(),      // nullifier
    amount.toString(),                      // amount
    BigInt(CONFIG.GHOST_TOKEN).toString(), // tokenAddress (address(this) in contract)
    BigInt(wallet.address).toString(),     // recipient
  ];
  console.log('Public inputs for verifier:');
  debugPublicInputs.forEach((v, i) => console.log(`  [${i}]: ${v}`));

  try {
    const verifyResult = await verifierProxy.verifyRedemptionProof(proofBytes, debugPublicInputs);
    console.log('Direct verifier call result:', verifyResult);
  } catch (e) {
    console.log('Direct verifier call failed:', e.message);
  }

  // === Direct RedeemVerifier call (bypass proxy) ===
  console.log('\n[Debug] Testing RedeemVerifier DIRECTLY (bypass proxy)...');
  const redeemVerifierAbi = [
    'function verifyProof(uint256[2] calldata _pA, uint256[2][2] calldata _pB, uint256[2] calldata _pC, uint256[6] calldata _pubSignals) view returns (bool)',
  ];
  const redeemVerifierDirect = new Contract(redeemVerifierAddr, redeemVerifierAbi, wallet);

  // Decode the proof bytes to get pA, pB, pC, commitmentOut
  const decodedProof = ethers.utils.defaultAbiCoder.decode(
    ['uint256[2]', 'uint256[2][2]', 'uint256[2]', 'uint256'],
    proofBytes
  );
  const [pA_decoded, pB_decoded, pC_decoded, commitmentOut_decoded] = decodedProof;

  console.log('Decoded from proof bytes:');
  console.log('  pA:', pA_decoded.map(x => x.toString().slice(0, 20) + '...'));
  console.log('  pB:', pB_decoded.map(row => row.map(x => x.toString().slice(0, 20) + '...')));
  console.log('  pC:', pC_decoded.map(x => x.toString().slice(0, 20) + '...'));
  console.log('  commitmentOut:', commitmentOut_decoded.toString().slice(0, 30) + '...');

  // Build full 6-element pubSignals array as circuit expects
  // Order: [commitmentOut, merkleRoot, nullifier, amount, tokenAddress, recipient]
  const fullPubSignals = [
    commitmentOut_decoded.toString(),       // [0] commitmentOut
    publicSignals[1],                       // [1] merkleRoot (from circuit)
    publicSignals[2],                       // [2] nullifier (from circuit)
    publicSignals[3],                       // [3] amount
    publicSignals[4],                       // [4] tokenAddress
    publicSignals[5],                       // [5] recipient
  ];

  console.log('\nFull pubSignals for direct verifier call:');
  fullPubSignals.forEach((v, i) => console.log(`  [${i}]: ${v.toString().slice(0, 40)}...`));

  // Also print the circuit's original public signals for comparison
  console.log('\nCircuit original publicSignals:');
  publicSignals.forEach((v, i) => console.log(`  [${i}]: ${v.toString().slice(0, 40)}...`));

  try {
    const directResult = await redeemVerifierDirect.verifyProof(
      pA_decoded,
      pB_decoded,
      pC_decoded,
      fullPubSignals
    );
    console.log('\n>>> Direct RedeemVerifier result:', directResult);
  } catch (e) {
    console.log('\n>>> Direct RedeemVerifier failed:', e.message);
  }

  // Try with EXACT circuit publicSignals (no reordering)
  console.log('\n[Debug] Testing with EXACT circuit publicSignals order...');
  try {
    const exactResult = await redeemVerifierDirect.verifyProof(
      pA_decoded,
      pB_decoded,
      pC_decoded,
      publicSignals  // Use circuit's exact order
    );
    console.log('>>> Exact circuit order result:', exactResult);
  } catch (e) {
    console.log('>>> Exact circuit order failed:', e.message);
  }

  // === NEW: Test ZKsync-compatible RedeemVerifier ===
  console.log('\n[Debug] Testing NEW ZKsync-compatible RedeemVerifier...');
  const ZKSYNC_VERIFIER_ADDR = '0x9D55Db2F7EDa1f40B335dB72CF50F386AD06EfdA';
  const zksyncVerifier = new Contract(ZKSYNC_VERIFIER_ADDR, redeemVerifierAbi, wallet);

  try {
    // The ZKsync verifier expects B coordinates already swapped (which our SDK now does)
    const zksyncResult = await zksyncVerifier.verifyProof(
      pA_decoded,
      pB_decoded,  // Already swapped by SDK
      pC_decoded,
      publicSignals  // Use circuit's exact order
    );
    console.log('>>> ZKsync Verifier result:', zksyncResult);
    if (zksyncResult) {
      console.log('✅✅✅ ZKSYNC VERIFIER PASSED! ✅✅✅');
    }
  } catch (e) {
    console.log('>>> ZKsync Verifier failed:', e.message);
  }

  // === CRITICAL: Test the new WORKING verifier ===
  console.log('\n[Debug] Testing WORKING verifier (bytes memory pattern)...');
  const WORKING_VERIFIER_ADDR = '0x625CAe5a2D8f0C99D64eeF69978237EbbB8bEB39';
  const workingVerifier = new Contract(WORKING_VERIFIER_ADDR, redeemVerifierAbi, wallet);

  try {
    const workingResult = await workingVerifier.verifyProof(
      pA_decoded,
      pB_decoded,  // Already swapped by SDK
      pC_decoded,
      publicSignals  // Use circuit's exact order
    );
    console.log('>>> WORKING Verifier result:', workingResult);
    if (workingResult) {
      console.log('✅✅✅ WORKING VERIFIER PASSED! ✅✅✅');
    }
  } catch (e) {
    console.log('>>> WORKING Verifier failed:', e.message);
  }

  // === Debug: Compare pairing inputs ===
  console.log('\n[Debug] Comparing verifier pairing input vs manual construction...');
  const DEBUG_VERIFIER = '0x193dBd8F7fDac1Ae7fE97B2eACE4fFEBE50b0b3F';
  const debugVerifierAbi = [
    'function buildPairingInput(uint256[2] calldata _pA, uint256[2][2] calldata _pB, uint256[2] calldata _pC, uint256[6] calldata _pubSignals) view returns (bytes memory pairingInput, uint256 vkx, uint256 vky)',
    'function computeVkX(uint256[6] calldata _pubSignals) view returns (uint256 vkx, uint256 vky, bool success)',
    'function verifyWithDebug(uint256[2] calldata _pA, uint256[2][2] calldata _pB, uint256[2] calldata _pC, uint256[6] calldata _pubSignals) view returns (bool isValid, uint256 vkx, uint256 vky, bool pairingSuccess, uint256 pairingResult)',
    'function callPairingDirect(bytes memory pairingInput) view returns (bool success, uint256 result)',
  ];
  const debugVerifier = new Contract(DEBUG_VERIFIER, debugVerifierAbi, wallet);

  try {
    // Get verifier's pairing input using the DECODED proof (from SDK encoding)
    const [verifierPairingInput, verifierVkx, verifierVky] = await debugVerifier.buildPairingInput(
      pA_decoded,
      pB_decoded,
      pC_decoded,
      publicSignals
    );
    console.log('Verifier pairing input length:', (verifierPairingInput.length - 2) / 2, 'bytes');
    console.log('Verifier vk_x:', verifierVkx.toString().slice(0, 40) + '...');
    console.log('Verifier vk_y:', verifierVky.toString().slice(0, 40) + '...');

    // Now call ecPairing with the verifier's input
    const verifierPairingResult = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: verifierPairingInput,
      gasLimit: 10000000
    });
    console.log('Verifier pairing input result:', verifierPairingResult);
    if (verifierPairingResult && verifierPairingResult !== '0x') {
      const resultVal = BigInt(verifierPairingResult);
      console.log('  >>> Via provider.call: ' + (resultVal === 1n ? '✅ VALID' : '❌ INVALID'));
    } else {
      console.log('  >>> Via provider.call: ❌ FAILED (empty result)');
    }

    // CRITICAL TEST: Call ecPairing from WITHIN the contract using callPairingDirect
    console.log('\n[Debug] Calling ecPairing from WITHIN contract (callPairingDirect)...');
    const [pairingDirectSuccess, pairingDirectResult] = await debugVerifier.callPairingDirect(verifierPairingInput);
    console.log('  staticcall success:', pairingDirectSuccess);
    console.log('  pairing result:', pairingDirectResult.toString());
    console.log('  >>> Via contract: ' + (pairingDirectSuccess && pairingDirectResult.toString() === '1' ? '✅ VALID' : '❌ INVALID'));

    // CRITICAL TEST: Full verifyWithDebug (does everything the real verifier does)
    console.log('\n[Debug] Calling verifyWithDebug (full verification path)...');
    const [isValid, vkxDebug, vkyDebug, pairingSuccess, pairingResultDebug] = await debugVerifier.verifyWithDebug(
      pA_decoded,
      pB_decoded,
      pC_decoded,
      publicSignals
    );
    console.log('  isValid:', isValid);
    console.log('  vk_x:', vkxDebug.toString().slice(0, 40) + '...');
    console.log('  vk_y:', vkyDebug.toString().slice(0, 40) + '...');
    console.log('  pairingSuccess:', pairingSuccess);
    console.log('  pairingResult:', pairingResultDebug.toString());
    console.log('  >>> verifyWithDebug: ' + (isValid ? '✅ VALID' : '❌ INVALID'));

    if (isValid) {
      console.log('\n🎉🎉🎉 DEBUG VERIFIER PASSES! The issue is in the original verifier assembly.');
    } else if (pairingDirectSuccess && pairingDirectResult.toString() === '1') {
      console.log('\n⚠️ callPairingDirect passes but verifyWithDebug fails - issue in vk_x computation');
    } else {
      console.log('\n❌ ecPairing fails when called from within contract - ZKsync VM issue?');
    }
  } catch (e) {
    console.log('Debug verifier error:', e.message);
  }

  // === Manual pairing check ===
  console.log('\n[Debug] Manual pairing check (bypass Solidity entirely)...');

  // VK constants from RedeemVerifier.sol
  const VK = {
    q: BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583'),
    alpha: { x: BigInt('20491192805390485299153009773594534940189261866228447918068658471970481763042'),
             y: BigInt('9383485363053290200918347156157836566562967994039712273449902621266178545958') },
    beta: { x1: BigInt('4252822878758300859123897981450591353533073413197771768651442665752259397132'),
            x2: BigInt('6375614351688725206403948262868962793625744043794305715222011528459656738731'),
            y1: BigInt('21847035105528745403288232691147584728191162732299865338377159692350059136679'),
            y2: BigInt('10505242626370262277552901082094356697409835680220590971873171140371331206856') },
    gamma: { x1: BigInt('11559732032986387107991004021392285783925812861821192530917403151452391805634'),
             x2: BigInt('10857046999023057135944570762232829481370756359578518086990519993285655852781'),
             y1: BigInt('4082367875863433681332203403145435568316851327593401208105741076214120093531'),
             y2: BigInt('8495653923123431417604973247489272438418190587263600148770280649306958101930') },
    delta: { x1: BigInt('20350888953504529292581957091747121845563752736971104059618323202218945714590'),
             x2: BigInt('8583081352743229799300385965312194134924660539175052034339807229471068507088'),
             y1: BigInt('2592085192013015013867798842170414597918537878369062236649848723791766887621'),
             y2: BigInt('11465217057375663758956123966589569771281571929934660615304689272071623139794') },
    IC: [
      { x: BigInt('4660105224062536442592866842932767992502719645364308146262623643842326122865'),
        y: BigInt('17276901730849178086213024785125128610553839494895313238582016803949795804802') },
      { x: BigInt('10320827842497404403725324583763518947938473681109509213221447686170297527349'),
        y: BigInt('6187173621915260736338747049934887844961698620531672792634685378438750676349') },
      { x: BigInt('17542082800098777139901493985535836451893342617951008250429429064246556539398'),
        y: BigInt('13627564828478472787962950403094034729954196587517178410134804019198739094179') },
      { x: BigInt('9539374540367541168128243720672631410190128354841127145109735248299159914024'),
        y: BigInt('14404186048576416489427444347784772541493914545749661367331342876857874070171') },
      { x: BigInt('1743148767838639168062519156339511069182684664034038434564582669398850074469'),
        y: BigInt('10782048529733657836688691187298319781562120235098775243385721026535854273587') },
      { x: BigInt('6306198342163219331115614665632367283309042802375632509921127761862511259523'),
        y: BigInt('12748624647856286760174855962829479938531149270253081805613420859213557746483') },
      { x: BigInt('20629243252197495532357678917970863049585519289991248466635865876780586859068'),
        y: BigInt('10914819839403061375513758084743037691038967452577598178075977991459989620682') },
    ]
  };

  function toHex32(bn) {
    return bn.toString(16).padStart(64, '0');
  }

  async function ecMul(px, py, scalar) {
    const input = '0x' + toHex32(px) + toHex32(py) + toHex32(scalar);
    const result = await provider.call({
      to: '0x0000000000000000000000000000000000000007',
      data: input, gasLimit: 2000000
    });
    if (result.length < 130) return null;
    return { x: BigInt('0x' + result.slice(2, 66)), y: BigInt('0x' + result.slice(66, 130)) };
  }

  async function ecAdd(p1x, p1y, p2x, p2y) {
    const input = '0x' + toHex32(p1x) + toHex32(p1y) + toHex32(p2x) + toHex32(p2y);
    const result = await provider.call({
      to: '0x0000000000000000000000000000000000000006',
      data: input, gasLimit: 2000000
    });
    if (result.length < 130) return null;
    return { x: BigInt('0x' + result.slice(2, 66)), y: BigInt('0x' + result.slice(66, 130)) };
  }

  // Convert public signals to BigInt
  const pubSigs = publicSignals.map(s => BigInt(s));

  // Compute vk_x = IC0 + sum(IC[i] * pubSignals[i-1])
  console.log('Computing vk_x from public signals...');
  let vk_x = { x: VK.IC[0].x, y: VK.IC[0].y };
  for (let i = 1; i <= 6; i++) {
    const mulResult = await ecMul(VK.IC[i].x, VK.IC[i].y, pubSigs[i-1]);
    if (!mulResult) { console.log('ecMul failed for IC' + i); break; }
    const addResult = await ecAdd(vk_x.x, vk_x.y, mulResult.x, mulResult.y);
    if (!addResult) { console.log('ecAdd failed'); break; }
    vk_x = addResult;
  }
  console.log('vk_x computed:', vk_x.x.toString().slice(0, 30) + '...');

  // Extract proof points from raw snarkjs proof
  const pA = { x: BigInt(proof.pi_a[0]), y: BigInt(proof.pi_a[1]) };
  // Note: pB is already swapped in the SDK encoding, but for manual check we use raw snarkjs values
  // snarkjs pi_b is [[x0, x1], [y0, y1]] but we need [[x1, x0], [y1, y0]] for EIP-197
  const pB = {
    x1: BigInt(proof.pi_b[0][1]),  // x_im (swapped)
    x0: BigInt(proof.pi_b[0][0]),  // x_re (swapped)
    y1: BigInt(proof.pi_b[1][1]),  // y_im (swapped)
    y0: BigInt(proof.pi_b[1][0]),  // y_re (swapped)
  };
  const pC = { x: BigInt(proof.pi_c[0]), y: BigInt(proof.pi_c[1]) };

  // Build full pairing input: e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) = 1
  const negA = { x: pA.x, y: (VK.q - pA.y) % VK.q };

  let pairingInput = '0x';
  // Pair 1: -A, B
  pairingInput += toHex32(negA.x) + toHex32(negA.y);
  pairingInput += toHex32(pB.x1) + toHex32(pB.x0) + toHex32(pB.y1) + toHex32(pB.y0);  // Swapped
  // Pair 2: alpha, beta
  pairingInput += toHex32(VK.alpha.x) + toHex32(VK.alpha.y);
  pairingInput += toHex32(VK.beta.x1) + toHex32(VK.beta.x2) + toHex32(VK.beta.y1) + toHex32(VK.beta.y2);
  // Pair 3: vk_x, gamma
  pairingInput += toHex32(vk_x.x) + toHex32(vk_x.y);
  pairingInput += toHex32(VK.gamma.x1) + toHex32(VK.gamma.x2) + toHex32(VK.gamma.y1) + toHex32(VK.gamma.y2);
  // Pair 4: C, delta
  pairingInput += toHex32(pC.x) + toHex32(pC.y);
  pairingInput += toHex32(VK.delta.x1) + toHex32(VK.delta.x2) + toHex32(VK.delta.y1) + toHex32(VK.delta.y2);

  console.log('Pairing input length:', (pairingInput.length - 2) / 2, 'bytes');

  try {
    const pairingResult = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: pairingInput,
      gasLimit: 10000000
    });
    console.log('Pairing result:', pairingResult);
    if (pairingResult && pairingResult !== '0x') {
      const resultValue = BigInt(pairingResult);
      console.log('Result value:', resultValue.toString());
      if (resultValue === BigInt(1)) {
        console.log('✅✅✅ MANUAL PAIRING CHECK PASSED ✅✅✅');
      } else {
        console.log('❌ Manual pairing returned 0 - proof invalid');
      }
    } else {
      console.log('❌ Pairing returned empty');
    }
  } catch (e) {
    console.log('❌ Pairing call failed:', e.message);
  }

  // Also try WITHOUT the B swap
  console.log('\n[Debug] Manual pairing WITHOUT B swap...');
  let pairingInputNoSwap = '0x';
  pairingInputNoSwap += toHex32(negA.x) + toHex32(negA.y);
  pairingInputNoSwap += toHex32(BigInt(proof.pi_b[0][0])) + toHex32(BigInt(proof.pi_b[0][1]));  // No swap
  pairingInputNoSwap += toHex32(BigInt(proof.pi_b[1][0])) + toHex32(BigInt(proof.pi_b[1][1]));  // No swap
  pairingInputNoSwap += toHex32(VK.alpha.x) + toHex32(VK.alpha.y);
  pairingInputNoSwap += toHex32(VK.beta.x1) + toHex32(VK.beta.x2) + toHex32(VK.beta.y1) + toHex32(VK.beta.y2);
  pairingInputNoSwap += toHex32(vk_x.x) + toHex32(vk_x.y);
  pairingInputNoSwap += toHex32(VK.gamma.x1) + toHex32(VK.gamma.x2) + toHex32(VK.gamma.y1) + toHex32(VK.gamma.y2);
  pairingInputNoSwap += toHex32(pC.x) + toHex32(pC.y);
  pairingInputNoSwap += toHex32(VK.delta.x1) + toHex32(VK.delta.x2) + toHex32(VK.delta.y1) + toHex32(VK.delta.y2);

  try {
    const pairingResultNoSwap = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: pairingInputNoSwap,
      gasLimit: 10000000
    });
    console.log('Pairing result (no swap):', pairingResultNoSwap);
    if (pairingResultNoSwap && pairingResultNoSwap !== '0x') {
      const resultValueNoSwap = BigInt(pairingResultNoSwap);
      if (resultValueNoSwap === BigInt(1)) {
        console.log('✅ NO SWAP works - the swap is WRONG!');
      }
    }
  } catch (e) {
    console.log('No swap failed:', e.message);
  }

  console.log('\n[Debug] End of debug checks\n');

  const redeemTx = await ghostToken.redeem(
    amount,
    wallet.address,
    nullifierHash,
    localRoot,
    merkleProofBytes32,
    pathIndicesUint,
    proofBytes,
    { gasLimit: 5000000 }
  );

  console.log('Redeem TX:', redeemTx.hash);
  const redeemReceipt = await redeemTx.wait();
  console.log('Redeem confirmed in block:', redeemReceipt.blockNumber);

  // === Step 7: Verify success ===
  console.log('\n[Step 7] Verification...');

  const finalBalance = await ghostToken.balanceOf(wallet.address);
  console.log('Final token balance:', ethers.utils.formatEther(finalBalance), 'gTEST');

  const balanceChange = finalBalance - initialBalance + amount;
  console.log('Balance change:', ethers.utils.formatEther(balanceChange), 'gTEST (should be 0 after ghost+redeem)');

  console.log('\n' + '='.repeat(60));
  console.log('SUCCESS! Groth16 ZK proof verified on-chain!');
  console.log('='.repeat(60));

  return {
    commitment,
    leafIndex,
    nullifierHash,
    txHash: redeemTx.hash,
  };
}

main()
  .then(result => {
    console.log('\nTest result:', result);
    process.exit(0);
  })
  .catch(error => {
    console.error('\nTest FAILED:', error.message || error);
    console.error(error.stack);
    process.exit(1);
  });
