/**
 * Test BN254 precompiles on ZKsync Era L2
 * This script tests ecAdd (0x06), ecMul (0x07), and ecPairing (0x08)
 */
import { Provider, Wallet } from 'zksync-ethers';

const RPC_URL = 'http://127.0.0.1:3150';
const PRIVATE_KEY = '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c';

// BN254 curve parameters
const P = BigInt('21888242871839275222246405745257275088696311157297823662689037894645226208583'); // Field modulus
const N = BigInt('21888242871839275222246405745257275088548364400416034343698204186575808495617'); // Scalar field

// G1 generator point
const G1_X = BigInt('1');
const G1_Y = BigInt('2');

// G2 generator point (x = x0 + i*x1, y = y0 + i*y1)
const G2_X1 = BigInt('10857046999023057135944570762232829481370756359578518086990519993285655852781');
const G2_X0 = BigInt('11559732032986387107991004021392285783925812861821192530917403151452391805634');
const G2_Y1 = BigInt('8495653923123431417604973247489272438418190587263600148770280649306958101930');
const G2_Y0 = BigInt('4082367875863433681332203403145435568316851327593401208105741076214120093531');

function toHex32(bn) {
  return bn.toString(16).padStart(64, '0');
}

function concat(...hexStrings) {
  return '0x' + hexStrings.join('');
}

async function main() {
  console.log('='.repeat(60));
  console.log('BN254 Precompile Test on ZKsync Era L2');
  console.log('='.repeat(60));

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);

  // Test 1: ecAdd (precompile 0x06)
  console.log('\n--- Test 1: ecAdd (0x06) ---');
  console.log('Computing G1 + G1 = 2*G1');

  // Encode: P1.x || P1.y || P2.x || P2.y
  const ecAddInput = concat(
    toHex32(G1_X), toHex32(G1_Y),
    toHex32(G1_X), toHex32(G1_Y)
  );

  try {
    const ecAddResult = await provider.call({
      to: '0x0000000000000000000000000000000000000006',
      data: ecAddInput,
      gasLimit: 1000000
    });
    console.log('ecAdd result:', ecAddResult);

    if (ecAddResult.length >= 130) {
      const resultX = BigInt('0x' + ecAddResult.slice(2, 66));
      const resultY = BigInt('0x' + ecAddResult.slice(66, 130));
      console.log('Result X:', resultX.toString());
      console.log('Result Y:', resultY.toString());

      // Expected 2*G1:
      // X = 1368015179489954701390400359078579693043519447331113978918064868415326638035
      // Y = 9918110051302171585080402603319702774565515993150576347155970296011118125764
      const expected2G1X = BigInt('1368015179489954701390400359078579693043519447331113978918064868415326638035');
      const expected2G1Y = BigInt('9918110051302171585080402603319702774565515993150576347155970296011118125764');

      if (resultX === expected2G1X && resultY === expected2G1Y) {
        console.log('✅ ecAdd PASSED - Correctly computed 2*G1');
      } else {
        console.log('❌ ecAdd FAILED - Unexpected result');
        console.log('Expected X:', expected2G1X.toString());
        console.log('Expected Y:', expected2G1Y.toString());
      }
    } else {
      console.log('❌ ecAdd returned unexpected length:', ecAddResult.length);
    }
  } catch (e) {
    console.log('❌ ecAdd FAILED:', e.message);
  }

  // Test 2: ecMul (precompile 0x07)
  console.log('\n--- Test 2: ecMul (0x07) ---');
  console.log('Computing 2 * G1');

  // Encode: P.x || P.y || scalar
  const ecMulInput = concat(
    toHex32(G1_X), toHex32(G1_Y),
    toHex32(BigInt(2))
  );

  try {
    const ecMulResult = await provider.call({
      to: '0x0000000000000000000000000000000000000007',
      data: ecMulInput,
      gasLimit: 1000000
    });
    console.log('ecMul result:', ecMulResult);

    if (ecMulResult.length >= 130) {
      const resultX = BigInt('0x' + ecMulResult.slice(2, 66));
      const resultY = BigInt('0x' + ecMulResult.slice(66, 130));
      console.log('Result X:', resultX.toString());
      console.log('Result Y:', resultY.toString());

      const expected2G1X = BigInt('1368015179489954701390400359078579693043519447331113978918064868415326638035');
      const expected2G1Y = BigInt('9918110051302171585080402603319702774565515993150576347155970296011118125764');

      if (resultX === expected2G1X && resultY === expected2G1Y) {
        console.log('✅ ecMul PASSED - Correctly computed 2*G1');
      } else {
        console.log('❌ ecMul FAILED - Unexpected result');
        console.log('Expected X:', expected2G1X.toString());
        console.log('Expected Y:', expected2G1Y.toString());
      }
    } else {
      console.log('❌ ecMul returned unexpected length:', ecMulResult.length);
    }
  } catch (e) {
    console.log('❌ ecMul FAILED:', e.message);
  }

  // Test 3: ecPairing (precompile 0x08)
  console.log('\n--- Test 3: ecPairing (0x08) ---');
  console.log('Testing e(G1, G2) == e(G1, G2) (should return 1)');

  // For a valid pairing check: e(P1, Q1) * e(P2, Q2) = 1
  // We use: e(G1, G2) * e(-G1, G2) = 1
  // -G1 has coordinates (G1_X, P - G1_Y)
  const negG1Y = P - G1_Y;

  // Encode pairs: [G1.x, G1.y, G2.x1, G2.x0, G2.y1, G2.y0, -G1.x, -G1.y, G2.x1, G2.x0, G2.y1, G2.y0]
  // Note: G2 points are encoded as (x1, x0, y1, y0) for the imaginary extension
  const ecPairingInput = concat(
    // First pair: (G1, G2)
    toHex32(G1_X), toHex32(G1_Y),
    toHex32(G2_X0), toHex32(G2_X1),
    toHex32(G2_Y0), toHex32(G2_Y1),
    // Second pair: (-G1, G2)
    toHex32(G1_X), toHex32(negG1Y),
    toHex32(G2_X0), toHex32(G2_X1),
    toHex32(G2_Y0), toHex32(G2_Y1)
  );

  console.log('ecPairing input length:', ecPairingInput.length, 'bytes');
  console.log('Expected: 770 bytes (2 + 12*64)');

  try {
    const ecPairingResult = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: ecPairingInput,
      gasLimit: 5000000
    });
    console.log('ecPairing result:', ecPairingResult);

    if (ecPairingResult.length >= 66) {
      const result = BigInt(ecPairingResult);
      console.log('Result value:', result.toString());

      if (result === BigInt(1)) {
        console.log('✅ ecPairing PASSED - Pairing check returned true');
      } else {
        console.log('❌ ecPairing FAILED - Expected 1, got', result.toString());
      }
    } else {
      console.log('Result length:', ecPairingResult.length);
      if (ecPairingResult === '0x') {
        console.log('❌ ecPairing returned empty - precompile may not be available');
      }
    }
  } catch (e) {
    console.log('❌ ecPairing FAILED:', e.message);

    // Try with more gas
    console.log('\nRetrying with 10M gas...');
    try {
      const ecPairingResult2 = await provider.call({
        to: '0x0000000000000000000000000000000000000008',
        data: ecPairingInput,
        gasLimit: 10000000
      });
      console.log('ecPairing result (10M gas):', ecPairingResult2);
    } catch (e2) {
      console.log('Still failed:', e2.message);
    }
  }

  // Test 4: Simple pairing that should return 0 (false)
  console.log('\n--- Test 4: ecPairing false test ---');
  console.log('Testing e(G1, G2) * e(G1, G2) (should return 0 - not balanced)');

  const ecPairingFalseInput = concat(
    toHex32(G1_X), toHex32(G1_Y),
    toHex32(G2_X0), toHex32(G2_X1),
    toHex32(G2_Y0), toHex32(G2_Y1),
    toHex32(G1_X), toHex32(G1_Y),  // Same G1, not negated
    toHex32(G2_X0), toHex32(G2_X1),
    toHex32(G2_Y0), toHex32(G2_Y1)
  );

  try {
    const ecPairingFalseResult = await provider.call({
      to: '0x0000000000000000000000000000000000000008',
      data: ecPairingFalseInput,
      gasLimit: 5000000
    });
    console.log('ecPairing false test result:', ecPairingFalseResult);

    const resultFalse = BigInt(ecPairingFalseResult);
    if (resultFalse === BigInt(0)) {
      console.log('✅ ecPairing false test PASSED - Returned 0 as expected');
    } else {
      console.log('❌ ecPairing false test FAILED - Expected 0, got', resultFalse.toString());
    }
  } catch (e) {
    console.log('❌ ecPairing false test FAILED:', e.message);
  }

  console.log('\n' + '='.repeat(60));
  console.log('Precompile tests complete');
  console.log('='.repeat(60));
}

main().catch(console.error);
