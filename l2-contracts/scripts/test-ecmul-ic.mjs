/**
 * Test ecMul with actual IC values from RedeemVerifier verification key
 * This tests if the precompile works correctly with large field elements
 */
import { Provider, Wallet } from 'zksync-ethers';

const RPC_URL = 'http://127.0.0.1:3150';
const PRIVATE_KEY = '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c';

// IC values from the verification key (same as in RedeemVerifier)
const IC1 = {
  x: BigInt('10320827842497404403725324583763518947938473681109509213221447686170297527349'),
  y: BigInt('6187173621915260736338747049934887844961698620531672792634685378438750676349')
};

// Sample public signal from E2E test
const testPubSignal = BigInt('3581942950880924147914917454015966041590272927722769155167955325621392993095');

function toHex32(bn) {
  return bn.toString(16).padStart(64, '0');
}

async function main() {
  console.log('EC Scalar Multiplication Test with IC Values');
  console.log('='.repeat(60));

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);

  // Test 1: ecMul with IC1 and pubSignal
  console.log('\n--- Test 1: ecMul(IC1, pubSignal) ---');
  console.log('IC1.x:', IC1.x.toString().slice(0, 20) + '...');
  console.log('IC1.y:', IC1.y.toString().slice(0, 20) + '...');
  console.log('scalar:', testPubSignal.toString().slice(0, 20) + '...');

  // Build ecMul input: point.x | point.y | scalar
  const ecMulInput = '0x' + toHex32(IC1.x) + toHex32(IC1.y) + toHex32(testPubSignal);
  console.log('Input length:', (ecMulInput.length - 2) / 2, 'bytes');

  try {
    const ecMulResult = await provider.call({
      to: '0x0000000000000000000000000000000000000007',
      data: ecMulInput,
      gasLimit: 2000000
    });

    console.log('ecMul result:', ecMulResult);

    if (ecMulResult === '0x') {
      console.log('❌ ecMul returned empty result - FAILED');
    } else if (ecMulResult.length >= 130) {
      const resultX = BigInt('0x' + ecMulResult.slice(2, 66));
      const resultY = BigInt('0x' + ecMulResult.slice(66, 130));
      console.log('Result X:', resultX.toString().slice(0, 30) + '...');
      console.log('Result Y:', resultY.toString().slice(0, 30) + '...');
      console.log('✅ ecMul succeeded');
    } else {
      console.log('❌ Unexpected result length:', ecMulResult.length);
    }
  } catch (e) {
    console.log('❌ ecMul FAILED:', e.message);
  }

  // Test 2: ecMul with scalar = 1 (should return the point itself)
  console.log('\n--- Test 2: ecMul(IC1, 1) - should return IC1 ---');

  const ecMulInput2 = '0x' + toHex32(IC1.x) + toHex32(IC1.y) + toHex32(BigInt(1));

  try {
    const ecMulResult2 = await provider.call({
      to: '0x0000000000000000000000000000000000000007',
      data: ecMulInput2,
      gasLimit: 2000000
    });

    if (ecMulResult2.length >= 130) {
      const resultX = BigInt('0x' + ecMulResult2.slice(2, 66));
      const resultY = BigInt('0x' + ecMulResult2.slice(66, 130));

      if (resultX === IC1.x && resultY === IC1.y) {
        console.log('✅ ecMul(P, 1) = P - PASSED');
      } else {
        console.log('❌ ecMul(P, 1) != P - FAILED');
        console.log('Expected X:', IC1.x.toString());
        console.log('Got X:', resultX.toString());
      }
    }
  } catch (e) {
    console.log('❌ ecMul FAILED:', e.message);
  }

  // Test 3: ecMul with scalar = 0 (should return point at infinity)
  console.log('\n--- Test 3: ecMul(IC1, 0) - should return point at infinity ---');

  const ecMulInput3 = '0x' + toHex32(IC1.x) + toHex32(IC1.y) + toHex32(BigInt(0));

  try {
    const ecMulResult3 = await provider.call({
      to: '0x0000000000000000000000000000000000000007',
      data: ecMulInput3,
      gasLimit: 2000000
    });

    if (ecMulResult3.length >= 130) {
      const resultX = BigInt('0x' + ecMulResult3.slice(2, 66));
      const resultY = BigInt('0x' + ecMulResult3.slice(66, 130));

      if (resultX === BigInt(0) && resultY === BigInt(0)) {
        console.log('✅ ecMul(P, 0) = O - PASSED (point at infinity)');
      } else {
        console.log('Result X:', resultX.toString());
        console.log('Result Y:', resultY.toString());
        console.log('(Note: point at infinity representation may vary)');
      }
    }
  } catch (e) {
    console.log('ecMul(P,0) error:', e.message);
  }

  // Test 4: Full vk_x computation check
  // vk_x = IC0 + IC1*pubSignals[0] + IC2*pubSignals[1] + ...
  // Let's just compute IC0 + IC1*pubSignals[0] and see if it works
  console.log('\n--- Test 4: Compute IC0 + IC1*pubSignals[0] ---');

  const IC0 = {
    x: BigInt('4660105224062536442592866842932767992502719645364308146262623643842326122865'),
    y: BigInt('17276901730849178086213024785125128610553839494895313238582016803949795804802')
  };

  // First: IC1 * pubSignal
  const mul1Input = '0x' + toHex32(IC1.x) + toHex32(IC1.y) + toHex32(testPubSignal);

  try {
    const mul1Result = await provider.call({
      to: '0x0000000000000000000000000000000000000007',
      data: mul1Input,
      gasLimit: 2000000
    });

    if (mul1Result.length >= 130) {
      const mul1X = BigInt('0x' + mul1Result.slice(2, 66));
      const mul1Y = BigInt('0x' + mul1Result.slice(66, 130));

      console.log('IC1*pubSignal computed');

      // Then: IC0 + (IC1 * pubSignal)
      const addInput = '0x' + toHex32(IC0.x) + toHex32(IC0.y) + toHex32(mul1X) + toHex32(mul1Y);

      const addResult = await provider.call({
        to: '0x0000000000000000000000000000000000000006',
        data: addInput,
        gasLimit: 2000000
      });

      if (addResult.length >= 130) {
        const addX = BigInt('0x' + addResult.slice(2, 66));
        const addY = BigInt('0x' + addResult.slice(66, 130));
        console.log('IC0 + IC1*pubSignal:');
        console.log('  X:', addX.toString().slice(0, 30) + '...');
        console.log('  Y:', addY.toString().slice(0, 30) + '...');
        console.log('✅ vk_x partial computation succeeded');
      }
    }
  } catch (e) {
    console.log('❌ vk_x computation FAILED:', e.message);
  }

  console.log('\n' + '='.repeat(60));
}

main().catch(console.error);
