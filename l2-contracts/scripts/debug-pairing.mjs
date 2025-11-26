/**
 * Debug the exact pairing call that happens in RedeemVerifier
 * This mirrors the verifier's assembly code to isolate the pairing issue
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

async function ecPairing(provider, pairs) {
  // pairs is array of { g1: {x, y}, g2: {x1, x2, y1, y2} }
  let input = '0x';
  for (const pair of pairs) {
    input += toHex32(pair.g1.x);
    input += toHex32(pair.g1.y);
    input += toHex32(pair.g2.x1);
    input += toHex32(pair.g2.x2);
    input += toHex32(pair.g2.y1);
    input += toHex32(pair.g2.y2);
  }

  console.log('Pairing input length:', (input.length - 2) / 2, 'bytes');

  const result = await provider.call({
    to: '0x0000000000000000000000000000000000000008',
    data: input,
    gasLimit: 10000000
  });

  console.log('Pairing raw result:', result);
  return result.length >= 66 ? BigInt(result) : null;
}

async function main() {
  console.log('Pairing Debug Test');
  console.log('='.repeat(60));

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);

  // Use actual public signals from the failed test
  const pubSignals = [
    BigInt('4057452067805879477866579511472211920729947090990343033566258606837318180543'),  // commitmentOut
    BigInt('2939206218805374857859602404150435308027614247970491409070860967604834435174'),  // merkleRoot
    BigInt('6444200880228698771777499520035518070121308961566457507718263421656571890500'),  // nullifier
    BigInt('10000000000000000000'),  // amount
    BigInt('627359587436901858083402959313367534323465013017'),  // tokenAddress
    BigInt('243347715708386741215890657052139825657855322460'),  // recipient
  ];

  console.log('\n[Step 1] Computing vk_x = IC0 + sum(IC[i] * pubSignals[i])...');

  // Start with IC0
  let vk_x = { x: VK.IC[0].x, y: VK.IC[0].y };
  console.log('Starting vk_x (IC0):', vk_x.x.toString().slice(0, 20) + '...');

  // Add IC[i] * pubSignals[i-1] for i = 1..6
  for (let i = 1; i <= 6; i++) {
    console.log(`\nComputing IC${i} * pubSignals[${i-1}]...`);
    const mulResult = await ecMul(provider, VK.IC[i].x, VK.IC[i].y, pubSignals[i-1]);
    if (!mulResult) {
      console.log('❌ ecMul failed!');
      return;
    }
    console.log('  Mul result:', mulResult.x.toString().slice(0, 20) + '...');

    const addResult = await ecAdd(provider, vk_x.x, vk_x.y, mulResult.x, mulResult.y);
    if (!addResult) {
      console.log('❌ ecAdd failed!');
      return;
    }
    vk_x = addResult;
    console.log('  Running vk_x:', vk_x.x.toString().slice(0, 20) + '...');
  }

  console.log('\n✅ Final vk_x computed:');
  console.log('  x:', vk_x.x.toString());
  console.log('  y:', vk_x.y.toString());

  // Now test the pairing with different G2 encodings
  console.log('\n[Step 2] Testing pairing encodings...');

  // The verifier uses this encoding for G2 points:
  // mstore(_pPairing, 448), gammax1)  // First word
  // mstore(_pPairing, 480), gammax2)  // Second word
  // mstore(_pPairing, 512), gammay1)  // Third word
  // mstore(_pPairing, 544), gammay2)  // Fourth word
  //
  // So the encoding is: x1, x2, y1, y2
  // Which based on naming convention is: x_re, x_im, y_re, y_im

  // Test 1: Using verifier's encoding (x1, x2, y1, y2)
  console.log('\n--- Test A: Verifier encoding (x1, x2, y1, y2) ---');

  // Simple test: e(G1, G2) * e(-G1, G2) = 1
  const G1 = { x: BigInt(1), y: BigInt(2) };
  const negG1 = { x: BigInt(1), y: VK.q - BigInt(2) };

  // Gamma is the G2 generator in snarkjs convention
  const G2_verifier = {
    x1: VK.gammax1,  // As stored by verifier
    x2: VK.gammax2,
    y1: VK.gammay1,
    y2: VK.gammay2
  };

  console.log('G2 (verifier encoding):');
  console.log('  x1:', G2_verifier.x1.toString().slice(0, 20) + '...');
  console.log('  x2:', G2_verifier.x2.toString().slice(0, 20) + '...');
  console.log('  y1:', G2_verifier.y1.toString().slice(0, 20) + '...');
  console.log('  y2:', G2_verifier.y2.toString().slice(0, 20) + '...');

  const pairingResultA = await ecPairing(provider, [
    { g1: G1, g2: G2_verifier },
    { g1: negG1, g2: G2_verifier }
  ]);

  console.log('Result A:', pairingResultA?.toString());
  if (pairingResultA === BigInt(1)) {
    console.log('✅ Verifier encoding works for e(G1,G2)*e(-G1,G2)');
  } else {
    console.log('❌ Verifier encoding FAILED');
  }

  // Test 2: Try swapped encoding (x2, x1, y2, y1) - standard EIP-197
  console.log('\n--- Test B: Swapped encoding (x2, x1, y2, y1) ---');

  const G2_swapped = {
    x1: VK.gammax2,  // Swap
    x2: VK.gammax1,
    y1: VK.gammay2,  // Swap
    y2: VK.gammay1
  };

  const pairingResultB = await ecPairing(provider, [
    { g1: G1, g2: G2_swapped },
    { g1: negG1, g2: G2_swapped }
  ]);

  console.log('Result B:', pairingResultB?.toString());
  if (pairingResultB === BigInt(1)) {
    console.log('✅ Swapped encoding works');
  } else {
    console.log('❌ Swapped encoding FAILED');
  }

  // Test 3: Try another permutation (x1, x2, y2, y1)
  console.log('\n--- Test C: Mixed encoding (x1, x2, y2, y1) ---');

  const G2_mixed = {
    x1: VK.gammax1,
    x2: VK.gammax2,
    y1: VK.gammay2,  // Only swap y
    y2: VK.gammay1
  };

  const pairingResultC = await ecPairing(provider, [
    { g1: G1, g2: G2_mixed },
    { g1: negG1, g2: G2_mixed }
  ]);

  console.log('Result C:', pairingResultC?.toString());

  // Test 4: Another permutation (x2, x1, y1, y2)
  console.log('\n--- Test D: Mixed encoding (x2, x1, y1, y2) ---');

  const G2_mixed2 = {
    x1: VK.gammax2,  // Only swap x
    x2: VK.gammax1,
    y1: VK.gammay1,
    y2: VK.gammay2
  };

  const pairingResultD = await ecPairing(provider, [
    { g1: G1, g2: G2_mixed2 },
    { g1: negG1, g2: G2_mixed2 }
  ]);

  console.log('Result D:', pairingResultD?.toString());

  console.log('\n' + '='.repeat(60));
  console.log('Summary:');
  console.log('  Test A (verifier x1,x2,y1,y2):', pairingResultA?.toString() === '1' ? '✅ PASS' : '❌ FAIL');
  console.log('  Test B (swapped x2,x1,y2,y1):', pairingResultB?.toString() === '1' ? '✅ PASS' : '❌ FAIL');
  console.log('  Test C (mixed x1,x2,y2,y1):', pairingResultC?.toString() === '1' ? '✅ PASS' : '❌ FAIL');
  console.log('  Test D (mixed x2,x1,y1,y2):', pairingResultD?.toString() === '1' ? '✅ PASS' : '❌ FAIL');
}

main().catch(console.error);
