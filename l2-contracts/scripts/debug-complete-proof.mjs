/**
 * Complete debug: Generate proof, verify locally, then manually perform
 * the exact same pairing check that RedeemVerifier does
 */
import { Provider, Wallet } from 'zksync-ethers';
import { ethers } from 'ethers';
import * as fs from 'fs';

const RPC_URL = 'http://127.0.0.1:3150';
const PRIVATE_KEY = '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c';

const CIRCUIT_BASE = '/Users/nathanpeterson/Desktop/Development/zksync-era-ghost-gas/sdk/ghost-ui/public/circuits/redeem';

// From RedeemVerifier.sol verification key
const VK = {
  q: BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583'),
  r: BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617'),

  alpha: {
    x: BigInt('20491192805390485299153009773594534940189261866228447918068658471970481763042'),
    y: BigInt('9383485363053290200918347156157836566562967994039712273449902621266178545958'),
  },
  beta: {
    x1: BigInt('4252822878758300859123897981450591353533073413197771768651442665752259397132'),
    x2: BigInt('6375614351688725206403948262868962793625744043794305715222011528459656738731'),
    y1: BigInt('21847035105528745403288232691147584728191162732299865338377159692350059136679'),
    y2: BigInt('10505242626370262277552901082094356697409835680220590971873171140371331206856'),
  },
  gamma: {
    x1: BigInt('11559732032986387107991004021392285783925812861821192530917403151452391805634'),
    x2: BigInt('10857046999023057135944570762232829481370756359578518086990519993285655852781'),
    y1: BigInt('4082367875863433681332203403145435568316851327593401208105741076214120093531'),
    y2: BigInt('8495653923123431417604973247489272438418190587263600148770280649306958101930'),
  },
  delta: {
    x1: BigInt('20350888953504529292581957091747121845563752736971104059618323202218945714590'),
    x2: BigInt('8583081352743229799300385965312194134924660539175052034339807229471068507088'),
    y1: BigInt('2592085192013015013867798842170414597918537878369062236649848723791766887621'),
    y2: BigInt('11465217057375663758956123966589569771281571929934660615304689272071623139794'),
  },
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

async function ecMul(provider, px, py, scalar) {
  const input = '0x' + toHex32(px) + toHex32(py) + toHex32(scalar);
  const result = await provider.call({
    to: '0x0000000000000000000000000000000000000007',
    data: input,
    gasLimit: 2000000
  });
  if (result.length < 130 || result === '0x') return null;
  return {
    x: BigInt('0x' + result.slice(2, 66)),
    y: BigInt('0x' + result.slice(66, 130))
  };
}

async function ecAdd(provider, p1x, p1y, p2x, p2y) {
  const input = '0x' + toHex32(p1x) + toHex32(p1y) + toHex32(p2x) + toHex32(p2y);
  const result = await provider.call({
    to: '0x0000000000000000000000000000000000000006',
    data: input,
    gasLimit: 2000000
  });
  if (result.length < 130 || result === '0x') return null;
  return {
    x: BigInt('0x' + result.slice(2, 66)),
    y: BigInt('0x' + result.slice(66, 130))
  };
}

async function getPoseidon() {
  const circomlibjs = await import('circomlibjs');
  return await circomlibjs.buildPoseidon();
}

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

  for (let i = 0; i < leaves.length; i++) {
    tree[0].set(i, leaves[i]);
  }

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
  console.log('Complete Proof Debug');
  console.log('='.repeat(60));

  const snarkjs = await import('snarkjs');
  const poseidon = await getPoseidon();
  const F = poseidon.F;

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);

  // Generate test data
  console.log('\n[Step 1] Generating test commitment...');

  const secretBuf = ethers.utils.randomBytes(31);
  const secret = BigInt('0x' + Buffer.from(secretBuf).toString('hex'));
  const amount = BigInt('10000000000000000000');
  const tokenAddress = BigInt(wallet.address);
  const recipient = BigInt(wallet.address);
  const leafIndex = 3;

  const nullifierHash = F.toObject(poseidon([secret, BigInt(leafIndex)]));
  const commitment = F.toObject(poseidon([secret, nullifierHash, amount, tokenAddress]));

  console.log('Secret:', secret.toString().slice(0, 20) + '...');
  console.log('Nullifier:', nullifierHash.toString().slice(0, 20) + '...');
  console.log('Commitment:', commitment.toString().slice(0, 20) + '...');

  // Build Merkle tree
  console.log('\n[Step 2] Building Merkle tree...');
  const leaves = [];
  for (let i = 0; i < leafIndex; i++) {
    leaves.push(BigInt(i + 1));
  }
  leaves.push(commitment);

  const merkleTree = buildMerkleTree(poseidon, leaves, 20);
  const root = merkleTree.root;
  const { pathElements, pathIndices } = merkleTree.getProof(leafIndex);
  console.log('Root:', root.toString().slice(0, 20) + '...');

  // Generate ZK proof
  console.log('\n[Step 3] Generating Groth16 proof...');

  const circuitInput = {
    merkleRoot: root.toString(),
    nullifier: nullifierHash.toString(),
    amount: amount.toString(),
    tokenAddress: tokenAddress.toString(),
    recipient: recipient.toString(),
    secret: secret.toString(),
    leafIndex: leafIndex.toString(),
    pathElements: pathElements.map(e => e.toString()),
    pathIndices: pathIndices.map(i => i.toString()),
  };

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInput,
    `${CIRCUIT_BASE}/redeem.wasm`,
    `${CIRCUIT_BASE}/redeem_final.zkey`
  );

  console.log('Proof generated!');
  console.log('Public signals:', publicSignals);

  // Verify locally
  console.log('\n[Step 4] Verifying locally...');
  const vkey = JSON.parse(fs.readFileSync(`${CIRCUIT_BASE}/verification_key.json`, 'utf-8'));
  const localValid = await snarkjs.groth16.verify(vkey, publicSignals, proof);
  console.log('Local verification:', localValid ? '✅ VALID' : '❌ INVALID');

  if (!localValid) {
    console.log('Local verification failed - stopping');
    return;
  }

  // Convert public signals to BigInt
  const pubSignals = publicSignals.map(s => BigInt(s));
  console.log('\nPublic signals (BigInt):');
  pubSignals.forEach((s, i) => console.log(`  [${i}]:`, s.toString().slice(0, 30) + '...'));

  // Now let's manually perform the pairing check
  console.log('\n[Step 5] Computing vk_x...');

  let vk_x = { x: VK.IC[0].x, y: VK.IC[0].y };
  for (let i = 1; i <= 6; i++) {
    const mulResult = await ecMul(provider, VK.IC[i].x, VK.IC[i].y, pubSignals[i-1]);
    if (!mulResult) {
      console.log(`❌ ecMul failed for IC${i}`);
      return;
    }
    const addResult = await ecAdd(provider, vk_x.x, vk_x.y, mulResult.x, mulResult.y);
    if (!addResult) {
      console.log(`❌ ecAdd failed after IC${i}`);
      return;
    }
    vk_x = addResult;
  }
  console.log('vk_x:', vk_x.x.toString().slice(0, 30) + '...');

  // Extract proof points
  console.log('\n[Step 6] Processing proof points...');

  // snarkjs proof format
  const pA = {
    x: BigInt(proof.pi_a[0]),
    y: BigInt(proof.pi_a[1])
  };

  // snarkjs pi_b is [[x0, x1], [y0, y1]] where x = x0 + i*x1
  // For Solidity, we need [[x1, x0], [y1, y0]] per EIP-197
  const pB = {
    // After the swap: [[pi_b[0][1], pi_b[0][0]], [pi_b[1][1], pi_b[1][0]]]
    // = [[x1, x0], [y1, y0]]
    // In memory this becomes: x1, x0, y1, y0 which is EIP-197 format
    x1: BigInt(proof.pi_b[0][1]),  // x_im
    x0: BigInt(proof.pi_b[0][0]),  // x_re
    y1: BigInt(proof.pi_b[1][1]),  // y_im
    y0: BigInt(proof.pi_b[1][0]),  // y_re
  };

  const pC = {
    x: BigInt(proof.pi_c[0]),
    y: BigInt(proof.pi_c[1])
  };

  console.log('pA:', pA.x.toString().slice(0, 20) + '...', pA.y.toString().slice(0, 20) + '...');
  console.log('pB.x1 (x_im):', pB.x1.toString().slice(0, 20) + '...');
  console.log('pB.x0 (x_re):', pB.x0.toString().slice(0, 20) + '...');
  console.log('pB.y1 (y_im):', pB.y1.toString().slice(0, 20) + '...');
  console.log('pB.y0 (y_re):', pB.y0.toString().slice(0, 20) + '...');
  console.log('pC:', pC.x.toString().slice(0, 20) + '...', pC.y.toString().slice(0, 20) + '...');

  // Now build the pairing input
  // The Groth16 equation: e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) = 1
  console.log('\n[Step 7] Building pairing input...');

  // -A = (A.x, q - A.y)
  const negA = { x: pA.x, y: (VK.q - pA.y) % VK.q };

  let pairingInput = '0x';

  // Pair 1: -A, B (proof points)
  pairingInput += toHex32(negA.x);
  pairingInput += toHex32(negA.y);
  pairingInput += toHex32(pB.x1);  // x_im (swapped)
  pairingInput += toHex32(pB.x0);  // x_re (swapped)
  pairingInput += toHex32(pB.y1);  // y_im (swapped)
  pairingInput += toHex32(pB.y0);  // y_re (swapped)

  // Pair 2: alpha, beta (VK)
  pairingInput += toHex32(VK.alpha.x);
  pairingInput += toHex32(VK.alpha.y);
  pairingInput += toHex32(VK.beta.x1);
  pairingInput += toHex32(VK.beta.x2);
  pairingInput += toHex32(VK.beta.y1);
  pairingInput += toHex32(VK.beta.y2);

  // Pair 3: vk_x, gamma (computed + VK)
  pairingInput += toHex32(vk_x.x);
  pairingInput += toHex32(vk_x.y);
  pairingInput += toHex32(VK.gamma.x1);
  pairingInput += toHex32(VK.gamma.x2);
  pairingInput += toHex32(VK.gamma.y1);
  pairingInput += toHex32(VK.gamma.y2);

  // Pair 4: C, delta (proof + VK)
  pairingInput += toHex32(pC.x);
  pairingInput += toHex32(pC.y);
  pairingInput += toHex32(VK.delta.x1);
  pairingInput += toHex32(VK.delta.x2);
  pairingInput += toHex32(VK.delta.y1);
  pairingInput += toHex32(VK.delta.y2);

  console.log('Pairing input length:', (pairingInput.length - 2) / 2, 'bytes (expected 768 for 4 pairs)');

  // Call pairing precompile
  console.log('\n[Step 8] Calling pairing precompile...');

  try {
    const pairingResult = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: pairingInput,
      gasLimit: 10000000
    });

    console.log('Raw result:', pairingResult);

    if (pairingResult && pairingResult !== '0x') {
      const resultValue = BigInt(pairingResult);
      console.log('Result value:', resultValue.toString());

      if (resultValue === BigInt(1)) {
        console.log('\n✅✅✅ PAIRING CHECK PASSED! ✅✅✅');
        console.log('The manual pairing check succeeded.');
        console.log('This means the issue is NOT in the proof or VK values.');
        console.log('The issue must be in how the Solidity verifier encodes the call.');
      } else {
        console.log('\n❌ PAIRING CHECK FAILED');
        console.log('Result is 0, meaning the pairing equation is not satisfied.');
        console.log('This could mean:');
        console.log('  1. Proof values are incorrect');
        console.log('  2. Public signals mismatch');
        console.log('  3. VK values mismatch');
        console.log('  4. B coordinate encoding is wrong');
      }
    } else {
      console.log('❌ Pairing returned empty result');
    }
  } catch (e) {
    console.log('❌ Pairing call failed:', e.message);
  }

  // Also try WITHOUT the B swap to see what happens
  console.log('\n[Step 9] Testing WITHOUT B swap (original snarkjs format)...');

  let pairingInputNoSwap = '0x';

  // Pair 1: -A, B (NO swap - original snarkjs format)
  pairingInputNoSwap += toHex32(negA.x);
  pairingInputNoSwap += toHex32(negA.y);
  pairingInputNoSwap += toHex32(BigInt(proof.pi_b[0][0]));  // x0 (NO swap)
  pairingInputNoSwap += toHex32(BigInt(proof.pi_b[0][1]));  // x1 (NO swap)
  pairingInputNoSwap += toHex32(BigInt(proof.pi_b[1][0]));  // y0 (NO swap)
  pairingInputNoSwap += toHex32(BigInt(proof.pi_b[1][1]));  // y1 (NO swap)

  // Rest is the same
  pairingInputNoSwap += toHex32(VK.alpha.x);
  pairingInputNoSwap += toHex32(VK.alpha.y);
  pairingInputNoSwap += toHex32(VK.beta.x1);
  pairingInputNoSwap += toHex32(VK.beta.x2);
  pairingInputNoSwap += toHex32(VK.beta.y1);
  pairingInputNoSwap += toHex32(VK.beta.y2);
  pairingInputNoSwap += toHex32(vk_x.x);
  pairingInputNoSwap += toHex32(vk_x.y);
  pairingInputNoSwap += toHex32(VK.gamma.x1);
  pairingInputNoSwap += toHex32(VK.gamma.x2);
  pairingInputNoSwap += toHex32(VK.gamma.y1);
  pairingInputNoSwap += toHex32(VK.gamma.y2);
  pairingInputNoSwap += toHex32(pC.x);
  pairingInputNoSwap += toHex32(pC.y);
  pairingInputNoSwap += toHex32(VK.delta.x1);
  pairingInputNoSwap += toHex32(VK.delta.x2);
  pairingInputNoSwap += toHex32(VK.delta.y1);
  pairingInputNoSwap += toHex32(VK.delta.y2);

  try {
    const pairingResultNoSwap = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: pairingInputNoSwap,
      gasLimit: 10000000
    });

    console.log('No-swap result:', pairingResultNoSwap);
    if (pairingResultNoSwap && pairingResultNoSwap !== '0x') {
      const resultValueNoSwap = BigInt(pairingResultNoSwap);
      console.log('Result value:', resultValueNoSwap.toString());
      if (resultValueNoSwap === BigInt(1)) {
        console.log('✅ NO SWAP works! The swap is WRONG!');
      }
    }
  } catch (e) {
    console.log('No-swap failed:', e.message);
  }

  console.log('\n' + '='.repeat(60));
}

main().catch(console.error);
