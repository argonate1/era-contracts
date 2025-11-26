/**
 * Debug the full Groth16 pairing check with actual proof values
 * This mimics exactly what RedeemVerifier does
 */
import { Provider, Wallet } from 'zksync-ethers';

const RPC_URL = 'http://127.0.0.1:3150';
const PRIVATE_KEY = '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c';

// From RedeemVerifier.sol verification key
const VK = {
  q: BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583'),
  r: BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617'),

  alphax: BigInt('20491192805390485299153009773594534940189261866228447918068658471970481763042'),
  alphay: BigInt('9383485363053290200918347156157836566562967994039712273449902621266178545958'),

  betax1: BigInt('4252822878758300859123897981450591353533073413197771768651442665752259397132'),
  betax2: BigInt('6375614351688725206403948262868962793625744043794305715222011528459656738731'),
  betay1: BigInt('21847035105528745403288232691147584728191162732299865338377159692350059136679'),
  betay2: BigInt('10505242626370262277552901082094356697409835680220590971873171140371331206856'),

  gammax1: BigInt('11559732032986387107991004021392285783925812861821192530917403151452391805634'),
  gammax2: BigInt('10857046999023057135944570762232829481370756359578518086990519993285655852781'),
  gammay1: BigInt('4082367875863433681332203403145435568316851327593401208105741076214120093531'),
  gammay2: BigInt('8495653923123431417604973247489272438418190587263600148770280649306958101930'),

  deltax1: BigInt('20350888953504529292581957091747121845563752736971104059618323202218945714590'),
  deltax2: BigInt('8583081352743229799300385965312194134924660539175052034339807229471068507088'),
  deltay1: BigInt('2592085192013015013867798842170414597918537878369062236649848723791766887621'),
  deltay2: BigInt('11465217057375663758956123966589569771281571929934660615304689272071623139794'),

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
  if (result.length < 130) return null;
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
  if (result.length < 130) return null;
  return {
    x: BigInt('0x' + result.slice(2, 66)),
    y: BigInt('0x' + result.slice(66, 130))
  };
}

async function main() {
  console.log('Full Groth16 Pairing Debug');
  console.log('='.repeat(60));

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);

  // Use actual values from the E2E test
  const pubSignals = [
    BigInt('4057452067805879477866579511472211920729947090990343033566258606837318180543'),  // commitmentOut
    BigInt('2939206218805374857859602404150435308027614247970491409070860967604834435174'),  // merkleRoot
    BigInt('6444200880228698771777499520035518070121308961566457507718263421656571890500'),  // nullifier
    BigInt('10000000000000000000'),  // amount
    BigInt('627359587436901858083402959313367534323465013017'),  // tokenAddress
    BigInt('243347715708386741215890657052139825657855322460'),  // recipient
  ];

  // These are the actual proof values from the E2E test (decoded from proofBytes)
  // The E2E test output showed:
  // pA: [ '11269640690087163078...', '14309013931268522664...' ]
  // pB: [[ '82063535014063336405...', '18649630140182898688...' ], [ '11591481558106126939...', '32662915763845643289...' ]]
  // pC: [ '16255603948555337613...', '11206998483823317154...' ]

  // Let me get the EXACT values from a fresh E2E run
  // For now, let me generate fresh proof values using snarkjs

  console.log('\n[Step 1] Computing vk_x from public signals...');

  // Compute vk_x = IC0 + sum(IC[i] * pubSignals[i-1])
  let vk_x = { x: VK.IC[0].x, y: VK.IC[0].y };

  for (let i = 1; i <= 6; i++) {
    const mulResult = await ecMul(provider, VK.IC[i].x, VK.IC[i].y, pubSignals[i-1]);
    if (!mulResult) {
      console.log(`❌ ecMul failed for IC${i}`);
      return;
    }
    const addResult = await ecAdd(provider, vk_x.x, vk_x.y, mulResult.x, mulResult.y);
    if (!addResult) {
      console.log(`❌ ecAdd failed for IC${i}`);
      return;
    }
    vk_x = addResult;
  }

  console.log('vk_x computed:');
  console.log('  x:', vk_x.x.toString());
  console.log('  y:', vk_x.y.toString());

  // Now let's test what the verifier actually does.
  // The Groth16 equation is:
  // e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) = 1

  // For verification, the verifier calls ecPairing with 4 pairs:
  // Pair 1: (-A, B) - proof points
  // Pair 2: (alpha, beta) - verification key
  // Pair 3: (vk_x, gamma) - computed vk_x and verification key gamma
  // Pair 4: (C, delta) - proof C and verification key delta

  console.log('\n[Step 2] Testing simple pairing with known-good values...');

  // First, let's test that the pairing works with trivial valid inputs
  // e(P, Q) * e(-P, Q) = 1 for any valid P, Q

  const simpleTest = await testSimplePairing(provider);
  if (!simpleTest) {
    console.log('❌ Simple pairing test failed - pairing precompile issue');
    return;
  }
  console.log('✅ Simple pairing test passed');

  // Now let's test with the verification key values only (no proof)
  // This should fail because we're missing the proof, but we can verify the encoding is correct
  console.log('\n[Step 3] Testing VK-only pairing structure...');

  // Build a pairing input that uses:
  // - alpha, beta (from VK)
  // - vk_x, gamma (computed + from VK)
  // But without the proof parts

  // The pairing check is: e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) = 1
  // If we just do e(alpha, beta) * e(vk_x, gamma) it won't equal 1, but it should return a result

  let pairingInput = '0x';

  // Pair 1: alpha, beta
  pairingInput += toHex32(VK.alphax);
  pairingInput += toHex32(VK.alphay);
  pairingInput += toHex32(VK.betax1);
  pairingInput += toHex32(VK.betax2);
  pairingInput += toHex32(VK.betay1);
  pairingInput += toHex32(VK.betay2);

  // Pair 2: vk_x, gamma
  pairingInput += toHex32(vk_x.x);
  pairingInput += toHex32(vk_x.y);
  pairingInput += toHex32(VK.gammax1);
  pairingInput += toHex32(VK.gammax2);
  pairingInput += toHex32(VK.gammay1);
  pairingInput += toHex32(VK.gammay2);

  console.log('Pairing input length:', (pairingInput.length - 2) / 2, 'bytes (expected 384 for 2 pairs)');

  const vkPairingResult = await provider.call({
    to: '0x0000000000000000000000000000000000000008',
    data: pairingInput,
    gasLimit: 10000000
  });

  console.log('VK-only pairing result:', vkPairingResult);
  if (vkPairingResult && vkPairingResult !== '0x') {
    const resultValue = BigInt(vkPairingResult);
    console.log('Result value:', resultValue.toString());
    console.log('✅ VK pairing structure is valid (returns a result)');
  } else {
    console.log('❌ VK pairing returned empty - invalid G2 points or encoding');
  }

  // Now let's examine what snarkjs outputs for pi_B
  console.log('\n[Step 4] Understanding snarkjs pi_B format...');
  console.log('snarkjs outputs pi_b as: [[x[0], x[1]], [y[0], y[1]]]');
  console.log('In Fp2, a point has x = x[0] + i*x[1]');
  console.log('EIP-197 expects G2 as: x_im, x_re, y_im, y_re = x[1], x[0], y[1], y[0]');
  console.log('');
  console.log('The verifier stores B as received from calldata:');
  console.log('  mstore(_pPairing+64, calldataload(pB))     // pB[0][0]');
  console.log('  mstore(_pPairing+96, calldataload(pB+32))  // pB[0][1]');
  console.log('  mstore(_pPairing+128, calldataload(pB+64)) // pB[1][0]');
  console.log('  mstore(_pPairing+160, calldataload(pB+96)) // pB[1][1]');
  console.log('');
  console.log('So for a valid proof, pB in Solidity should be:');
  console.log('  [[x_im, x_re], [y_im, y_re]] = [[pi_b[0][1], pi_b[0][0]], [pi_b[1][1], pi_b[1][0]]]');
  console.log('');
  console.log('This means we need to SWAP the coordinates within each pair!');

  console.log('\n' + '='.repeat(60));
}

async function testSimplePairing(provider) {
  // Test e(G1, G2) * e(-G1, G2) = 1
  const G1_x = BigInt(1);
  const G1_y = BigInt(2);
  const negG1_y = VK.q - BigInt(2);

  // G2 generator (same encoding as gamma in VK)
  const G2_x1 = BigInt('11559732032986387107991004021392285783925812861821192530917403151452391805634');
  const G2_x2 = BigInt('10857046999023057135944570762232829481370756359578518086990519993285655852781');
  const G2_y1 = BigInt('4082367875863433681332203403145435568316851327593401208105741076214120093531');
  const G2_y2 = BigInt('8495653923123431417604973247489272438418190587263600148770280649306958101930');

  let input = '0x';
  // Pair 1: G1, G2
  input += toHex32(G1_x);
  input += toHex32(G1_y);
  input += toHex32(G2_x1);
  input += toHex32(G2_x2);
  input += toHex32(G2_y1);
  input += toHex32(G2_y2);
  // Pair 2: -G1, G2
  input += toHex32(G1_x);
  input += toHex32(negG1_y);
  input += toHex32(G2_x1);
  input += toHex32(G2_x2);
  input += toHex32(G2_y1);
  input += toHex32(G2_y2);

  const result = await provider.call({
    to: '0x0000000000000000000000000000000000000008',
    data: input,
    gasLimit: 10000000
  });

  return result && BigInt(result) === BigInt(1);
}

main().catch(console.error);
