/**
 * Debug script to compare vk_x computation between manual JS and Solidity verifier
 */

import { Provider, Wallet, Contract } from 'zksync-ethers';
import { ethers } from 'ethers';

const CONFIG = {
  RPC_URL: 'http://127.0.0.1:3150',
  PRIVATE_KEY: '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c',
  DEBUG_VERIFIER: '0x193dBd8F7fDac1Ae7fE97B2eACE4fFEBE50b0b3F',
  OLD_VERIFIER: '0x177529B573cDe3481dD067559043b75672591eDa',
};

// VK IC points (same as verifier)
const IC = [
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
];

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
  return { x: BigInt('0x' + result.slice(2, 66)), y: BigInt('0x' + result.slice(66, 130)) };
}

async function ecAdd(provider, p1x, p1y, p2x, p2y) {
  const input = '0x' + toHex32(p1x) + toHex32(p1y) + toHex32(p2x) + toHex32(p2y);
  const result = await provider.call({
    to: '0x0000000000000000000000000000000000000006',
    data: input,
    gasLimit: 2000000
  });
  if (result.length < 130) return null;
  return { x: BigInt('0x' + result.slice(2, 66)), y: BigInt('0x' + result.slice(66, 130)) };
}

async function main() {
  console.log('='.repeat(60));
  console.log('VK_X Computation Debug');
  console.log('='.repeat(60));

  const provider = new Provider(CONFIG.RPC_URL);
  const wallet = new Wallet(CONFIG.PRIVATE_KEY, provider);

  // Use the same public signals from the E2E test
  const publicSignals = [
    BigInt('11770199256567894356762122377774253903396439874747218845968098960594046613269'),
    BigInt('21808880120728709793872363106056858506623450081661817934002736979741603705203'),
    BigInt('9907841454133819173636061428867738739498879076892195727842120562597042562844'),
    BigInt('10000000000000000000'),
    BigInt('627359587436901858083402959313367534323465013017'),
    BigInt('243347715708386741215890657052139825657855322460'),
  ];

  console.log('\nPublic Signals:');
  publicSignals.forEach((s, i) => console.log(`  [${i}]: ${s.toString()}`));

  // ===== Manual vk_x computation =====
  console.log('\n[1] Computing vk_x manually via precompiles...');
  let vk_x = { x: IC[0].x, y: IC[0].y };
  for (let i = 1; i <= 6; i++) {
    const mulResult = await ecMul(provider, IC[i].x, IC[i].y, publicSignals[i-1]);
    if (!mulResult) { console.log(`ecMul failed for IC${i}`); return; }
    const addResult = await ecAdd(provider, vk_x.x, vk_x.y, mulResult.x, mulResult.y);
    if (!addResult) { console.log('ecAdd failed'); return; }
    vk_x = addResult;
  }
  console.log('Manual vk_x:');
  console.log('  x:', vk_x.x.toString());
  console.log('  y:', vk_x.y.toString());

  // ===== Verifier vk_x computation =====
  console.log('\n[2] Computing vk_x via debug verifier...');
  const debugAbi = [
    'function computeVkX(uint256[6] calldata _pubSignals) view returns (uint256 vkx, uint256 vky, bool success)',
    'function verifyWithDebug(uint256[2] calldata _pA, uint256[2][2] calldata _pB, uint256[2] calldata _pC, uint256[6] calldata _pubSignals) view returns (bool isValid, uint256 vkx, uint256 vky, bool pairingSuccess, uint256 pairingResult)',
    'function buildPairingInput(uint256[2] calldata _pA, uint256[2][2] calldata _pB, uint256[2] calldata _pC, uint256[6] calldata _pubSignals) view returns (bytes memory pairingInput, uint256 vkx, uint256 vky)',
  ];
  const debugVerifier = new Contract(CONFIG.DEBUG_VERIFIER, debugAbi, wallet);

  const pubSigsArray = publicSignals.map(s => s.toString());

  try {
    const [vkxSol, vkySol, successSol] = await debugVerifier.computeVkX(pubSigsArray);
    console.log('Verifier vk_x:');
    console.log('  x:', vkxSol.toString());
    console.log('  y:', vkySol.toString());
    console.log('  success:', successSol);

    // Compare
    console.log('\n[3] Comparison:');
    const xMatch = vk_x.x.toString() === vkxSol.toString();
    const yMatch = vk_x.y.toString() === vkySol.toString();
    console.log('  x matches:', xMatch ? '✅ YES' : '❌ NO');
    console.log('  y matches:', yMatch ? '✅ YES' : '❌ NO');

    if (!xMatch || !yMatch) {
      console.log('\n  MISMATCH! Delta:');
      console.log('  x diff:', (vk_x.x - BigInt(vkxSol.toString())).toString());
      console.log('  y diff:', (vk_x.y - BigInt(vkySol.toString())).toString());
    }
  } catch (e) {
    console.log('Error calling computeVkX:', e.message);
  }

  // ===== Test with actual proof from E2E test =====
  console.log('\n[4] Testing with REAL proof data...');

  // Real proof data (from snarkjs, with B swap applied)
  // These are sample values - we need to extract from a real proof
  const rawProof = {
    pi_a: [
      "15348783385023018665034389088028403765652556266399788655527695741217905653768",
      "10052024211608856809046706556803419831566445456753788009379632686044855785614"
    ],
    pi_b: [
      ["8871376619638457120168704741413685609523393421889497689380085684696691127281", "21592149290257725971632696568628096389088579181892879254626959695553093813225"],
      ["10828651422518886398571785656478788628686660316610741458847336990990177787085", "17049493363563626674688561671095377890755735096058612785689851133765379295826"]
    ],
    pi_c: [
      "6704931620142268376613946024422419538193455645704741085310866737403652839442",
      "5048396520948820005296740695481232896970096765579879234696428866440025890610"
    ]
  };

  // Build pA, pB, pC with B swap (as SDK does)
  const pA = [rawProof.pi_a[0], rawProof.pi_a[1]];
  const pB = [
    [rawProof.pi_b[0][1], rawProof.pi_b[0][0]],  // Swap for ZKsync
    [rawProof.pi_b[1][1], rawProof.pi_b[1][0]],
  ];
  const pC = [rawProof.pi_c[0], rawProof.pi_c[1]];

  console.log('Proof points (with B swap):');
  console.log('  pA:', pA);
  console.log('  pB:', pB);
  console.log('  pC:', pC);

  try {
    // Get pairing input from debug verifier
    const [pairingInputSol, vkxP, vkyP] = await debugVerifier.buildPairingInput(
      pA, pB, pC, pubSigsArray
    );
    console.log('\n[5] Pairing input from verifier (first 384 bytes = 2 pairs):');
    console.log('  Length:', pairingInputSol.length, 'chars =', (pairingInputSol.length - 2) / 2, 'bytes');
    console.log('  Pair 1 (-A, B):');
    console.log('    -A.x:', BigInt('0x' + pairingInputSol.slice(2, 66)).toString().slice(0, 40) + '...');
    console.log('    -A.y:', BigInt('0x' + pairingInputSol.slice(66, 130)).toString().slice(0, 40) + '...');
    console.log('    B[0][0]:', BigInt('0x' + pairingInputSol.slice(130, 194)).toString().slice(0, 40) + '...');
    console.log('    B[0][1]:', BigInt('0x' + pairingInputSol.slice(194, 258)).toString().slice(0, 40) + '...');
    console.log('    B[1][0]:', BigInt('0x' + pairingInputSol.slice(258, 322)).toString().slice(0, 40) + '...');
    console.log('    B[1][1]:', BigInt('0x' + pairingInputSol.slice(322, 386)).toString().slice(0, 40) + '...');

    // Now build manual pairing input like the E2E test does
    console.log('\n[6] Building manual pairing input...');
    const q = BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583');
    const pA_big = [BigInt(pA[0]), BigInt(pA[1])];
    const negAy = (q - pA_big[1]) % q;

    // VK constants (same as in verifier)
    const VK = {
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
    };

    // Manual pairing input (like E2E test)
    let manualInput = '0x';
    // Pair 1: -A, B
    manualInput += toHex32(pA_big[0]) + toHex32(negAy);
    manualInput += toHex32(BigInt(pB[0][0])) + toHex32(BigInt(pB[0][1]));  // B[0] from calldata
    manualInput += toHex32(BigInt(pB[1][0])) + toHex32(BigInt(pB[1][1]));  // B[1] from calldata
    // Pair 2: alpha, beta
    manualInput += toHex32(VK.alpha.x) + toHex32(VK.alpha.y);
    manualInput += toHex32(VK.beta.x1) + toHex32(VK.beta.x2) + toHex32(VK.beta.y1) + toHex32(VK.beta.y2);
    // Pair 3: vk_x, gamma
    manualInput += toHex32(vk_x.x) + toHex32(vk_x.y);
    manualInput += toHex32(VK.gamma.x1) + toHex32(VK.gamma.x2) + toHex32(VK.gamma.y1) + toHex32(VK.gamma.y2);
    // Pair 4: C, delta
    manualInput += toHex32(BigInt(pC[0])) + toHex32(BigInt(pC[1]));
    manualInput += toHex32(VK.delta.x1) + toHex32(VK.delta.x2) + toHex32(VK.delta.y1) + toHex32(VK.delta.y2);

    console.log('  Manual pairing input length:', (manualInput.length - 2) / 2, 'bytes');

    // Compare byte by byte
    console.log('\n[7] Comparing pairing inputs...');
    let differences = 0;
    for (let i = 2; i < Math.min(pairingInputSol.length, manualInput.length); i += 64) {
      const solChunk = pairingInputSol.slice(i, i + 64);
      const manChunk = manualInput.slice(i, i + 64);
      if (solChunk !== manChunk) {
        const offset = (i - 2) / 2;
        const pairNum = Math.floor(offset / 192);
        const fieldNum = Math.floor((offset % 192) / 32);
        console.log(`  Diff at byte ${offset} (pair ${pairNum}, field ${fieldNum}):`);
        console.log(`    Sol: ${BigInt('0x' + solChunk).toString()}`);
        console.log(`    Man: ${BigInt('0x' + manChunk).toString()}`);
        differences++;
      }
    }
    if (differences === 0) {
      console.log('  ✅ Pairing inputs are IDENTICAL!');
    } else {
      console.log(`  ❌ Found ${differences} differences`);
    }

    // Call pairing with both inputs
    console.log('\n[8] Calling ecPairing precompile...');
    const solPairingResult = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: pairingInputSol,
      gasLimit: 10000000
    });
    console.log('  Solidity input result:', solPairingResult);

    const manPairingResult = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: manualInput,
      gasLimit: 10000000
    });
    console.log('  Manual input result:', manPairingResult);

  } catch (e) {
    console.log('Error:', e.message);
  }

  console.log('\n' + '='.repeat(60));
}

main().catch(console.error);
