/**
 * Test RedeemVerifier with fresh proof from snarkjs
 * This generates a proof and immediately tests it against the on-chain verifier
 */
import { Provider, Wallet, Contract } from 'zksync-ethers';
import { ethers } from 'ethers';
import * as path from 'path';
import * as fs from 'fs';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Import snarkjs dynamically
let snarkjs;

const RPC_URL = 'http://127.0.0.1:3150';
const PRIVATE_KEY = '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c';
const REDEEM_VERIFIER = '0x177529B573cDe3481dD067559043b75672591eDa';

const VERIFIER_ABI = [
  'function verifyProof(uint256[2] calldata _pA, uint256[2][2] calldata _pB, uint256[2] calldata _pC, uint256[6] calldata _pubSignals) view returns (bool)',
];

// Circuit paths
const CIRCUIT_BASE = '/Users/nathanpeterson/Desktop/Development/zksync-era-ghost-gas/sdk/ghost-ui/public/circuits/redeem';
const WASM_FILE = path.join(CIRCUIT_BASE, 'redeem.wasm');
const ZKEY_FILE = path.join(CIRCUIT_BASE, 'redeem_final.zkey');
const VKEY_FILE = path.join(CIRCUIT_BASE, 'verification_key.json');

// Poseidon hash function (using circomlibjs)
async function getPoseidon() {
  const circomlibjs = await import('circomlibjs');
  return await circomlibjs.buildPoseidon();
}

// Build a simple Merkle tree
function buildMerkleTree(poseidon, leaves, depth = 20) {
  const F = poseidon.F;
  const zeroValues = [BigInt(0)];
  for (let i = 1; i <= depth; i++) {
    zeroValues[i] = F.toObject(poseidon([zeroValues[i-1], zeroValues[i-1]]));
  }

  const tree = [new Map()];
  for (let i = 1; i <= depth; i++) {
    tree[i] = new Map();
  }

  // Insert leaves
  for (let i = 0; i < leaves.length; i++) {
    tree[0].set(i, leaves[i]);
  }

  // Build tree bottom-up
  for (let level = 0; level < depth; level++) {
    const numNodes = Math.ceil((tree[level].size || 1) / 2);
    for (let i = 0; i < numNodes; i++) {
      const left = tree[level].get(2*i) ?? zeroValues[level];
      const right = tree[level].get(2*i + 1) ?? zeroValues[level];
      tree[level + 1].set(i, F.toObject(poseidon([left, right])));
    }
  }

  return {
    root: tree[depth].get(0) ?? zeroValues[depth],
    tree,
    zeroValues,
    getProof: (index) => {
      const pathElements = [];
      const pathIndices = [];
      let currentIndex = index;

      for (let level = 0; level < depth; level++) {
        const isRight = currentIndex % 2 === 1;
        const siblingIndex = isRight ? currentIndex - 1 : currentIndex + 1;
        const sibling = tree[level].get(siblingIndex) ?? zeroValues[level];

        pathElements.push(sibling);
        pathIndices.push(isRight ? 1 : 0);

        currentIndex = Math.floor(currentIndex / 2);
      }

      return { pathElements, pathIndices };
    }
  };
}

async function main() {
  console.log('Fresh Proof Verifier Test');
  console.log('='.repeat(60));

  // Load snarkjs
  snarkjs = await import('snarkjs');
  const poseidon = await getPoseidon();
  const F = poseidon.F;

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const verifier = new Contract(REDEEM_VERIFIER, VERIFIER_ABI, wallet);

  console.log('\nWallet:', wallet.address);
  console.log('Verifier:', REDEEM_VERIFIER);

  // === Generate test data ===
  console.log('\n[Step 1] Generating test commitment...');

  // Generate random secret
  const secretBuf = ethers.utils.randomBytes(31);
  const secret = BigInt('0x' + Buffer.from(secretBuf).toString('hex'));
  console.log('Secret:', '0x' + secret.toString(16).slice(0, 16) + '...');

  // Parameters
  const amount = BigInt('10000000000000000000'); // 10 tokens
  const tokenAddress = BigInt(wallet.address);
  const recipient = BigInt(wallet.address);
  const leafIndex = 5; // Arbitrary leaf index

  // Compute nullifier hash
  const nullifierHash = F.toObject(poseidon([secret, BigInt(leafIndex)]));
  console.log('Nullifier hash:', '0x' + nullifierHash.toString(16).slice(0, 16) + '...');

  // Compute commitment
  const commitment = F.toObject(poseidon([secret, nullifierHash, amount, tokenAddress]));
  console.log('Commitment:', '0x' + commitment.toString(16).slice(0, 16) + '...');

  // === Build Merkle tree ===
  console.log('\n[Step 2] Building Merkle tree...');

  // Create leaves array with our commitment at the right index
  const leaves = [];
  for (let i = 0; i < leafIndex; i++) {
    leaves.push(BigInt(i + 1)); // Dummy leaves
  }
  leaves.push(commitment);

  const merkleTree = buildMerkleTree(poseidon, leaves, 20);
  const root = merkleTree.root;
  console.log('Merkle root:', '0x' + root.toString(16).slice(0, 16) + '...');

  const { pathElements, pathIndices } = merkleTree.getProof(leafIndex);

  // === Generate ZK proof ===
  console.log('\n[Step 3] Generating Groth16 proof...');

  // Circuit inputs (matching e2e-groth16-test.mjs)
  const circuitInput = {
    // Public inputs
    merkleRoot: root.toString(),
    nullifier: nullifierHash.toString(),
    amount: amount.toString(),
    tokenAddress: tokenAddress.toString(),
    recipient: recipient.toString(),

    // Private inputs
    secret: secret.toString(),
    leafIndex: leafIndex.toString(),
    pathElements: pathElements.map(e => e.toString()),
    pathIndices: pathIndices.map(i => i.toString()),
  };

  console.log('Generating proof...');
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInput,
    WASM_FILE,
    ZKEY_FILE
  );

  console.log('Proof generated!');
  console.log('Public signals:', publicSignals);

  // === Verify locally ===
  console.log('\n[Step 4] Verifying proof locally...');

  const vkey = JSON.parse(fs.readFileSync(VKEY_FILE, 'utf-8'));
  const isLocallyValid = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  console.log('Local verification:', isLocallyValid ? 'VALID' : 'INVALID');

  if (!isLocallyValid) {
    console.log('ERROR: Proof invalid locally!');
    return;
  }

  // === Prepare for on-chain verification ===
  console.log('\n[Step 5] Preparing for on-chain verification...');

  // snarkjs proof format -> Solidity format
  // Note: snarkjs pi_b is [[x1,x0],[y1,y0]] but Solidity expects [[x0,x1],[y0,y1]]
  const pA = [proof.pi_a[0], proof.pi_a[1]];
  const pB = [
    [proof.pi_b[0][1], proof.pi_b[0][0]], // Swap x coordinates
    [proof.pi_b[1][1], proof.pi_b[1][0]], // Swap y coordinates
  ];
  const pC = [proof.pi_c[0], proof.pi_c[1]];

  // Public signals array (already in circuit order)
  const pubSignals = publicSignals.map(s => s.toString());

  console.log('pA:', pA);
  console.log('pB:', pB);
  console.log('pC:', pC);
  console.log('pubSignals:', pubSignals);

  // === Call on-chain verifier ===
  console.log('\n[Step 6] Calling on-chain verifier...');

  try {
    const result = await verifier.verifyProof(pA, pB, pC, pubSignals);
    console.log('On-chain verification result:', result);

    if (result) {
      console.log('\n✅ SUCCESS: Proof verified on-chain!');
    } else {
      console.log('\n❌ FAILED: Proof rejected on-chain');

      // Debug: Let's check the raw call
      console.log('\n[Debug] Checking raw staticcall...');
      const calldata = verifier.interface.encodeFunctionData('verifyProof', [pA, pB, pC, pubSignals]);
      console.log('Calldata length:', calldata.length);

      const rawResult = await provider.call({
        to: REDEEM_VERIFIER,
        data: calldata,
      });
      console.log('Raw result:', rawResult);
    }
  } catch (e) {
    console.log('Verification call failed:', e.message);
  }

  // === Additional debug: Test with exact snarkjs format (no B swap) ===
  console.log('\n[Debug] Testing WITHOUT B coordinate swap...');

  const pB_noswap = [
    [proof.pi_b[0][0], proof.pi_b[0][1]], // Original snarkjs order
    [proof.pi_b[1][0], proof.pi_b[1][1]],
  ];

  try {
    const result2 = await verifier.verifyProof(pA, pB_noswap, pC, pubSignals);
    console.log('Without swap result:', result2);
  } catch (e) {
    console.log('Without swap failed:', e.message);
  }
}

main().catch(console.error);
