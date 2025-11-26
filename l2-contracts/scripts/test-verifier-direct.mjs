/**
 * Direct test of RedeemVerifier on Umbraline L2
 */
import { Provider, Wallet, Contract } from 'zksync-ethers';
import { ethers } from 'ethers';

const RPC_URL = 'http://127.0.0.1:3150';
const PRIVATE_KEY = '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c';
const REDEEM_VERIFIER = '0x177529B573cDe3481dD067559043b75672591eDa';

const VERIFIER_ABI = [
  'function verifyProof(uint256[2] calldata _pA, uint256[2][2] calldata _pB, uint256[2] calldata _pC, uint256[6] calldata _pubSignals) view returns (bool)',
];

// A known-valid Groth16 proof from local verification
// These values are from the last test run
// NOTE: snarkjs proof.pi_b format is [[c1, c0], [c1, c0]] but Solidity expects [[c0, c1], [c0, c1]]
// So we need to swap the coordinates within each inner array
const snarkjsProof = {
  a: ['0x251e54299b70e6b5060ff0455358774fbd285533a8bbeafc2c78736571e3f74d',
      '0x1268ab9636853f262bf997f10b0786bc73bc926a626e9fc9de9e2ebfe1016e94'],
  // Raw snarkjs b format (will be transformed below)
  b_raw: [['0x1d29177f421ff9c8d6f7960ffbc6161d6648e4f23f7da76de2fc219d3fc8f97a',
           '0x117ec9b5b0092b85d28d2e68b0a0e5250b82299dd143c33d01c7d6d30afb6a70'],
          ['0x218bc43d37cefbfba51d68668a02b322f44a1aef7147c74bb76ccbfd155afc20',
           '0x2409a913593f37ccf41e086f0cfcfa418c86efbdff6fd02ef07c68843dddd575']],
  c: ['0x02f2bc5ef559d58e6c5e7458f94e4449571a0644091dece5337073590058410f',
      '0x2eeddaabfa6482bddb788c97e60b42b869fa948ef5ab634bca734baa0d1e88d1'],
  pubSignals: [
    '15549167160844997990551328817325231177132756280562081738560624571141502339587',  // commitmentOut
    '11825905312977144813959371137766584920484279995258918490773547547108690611181',  // merkleRoot
    '16742180802194714756813918469581331375173562442152555259087348266493077853652',  // nullifier
    '10000000000000000000',  // amount
    '627359587436901858083402959313367534323465013017',  // tokenAddress
    '243347715708386741215890657052139825657855322460'   // recipient
  ]
};

// Transform pB from snarkjs format [[c1, c0], [c1, c0]] to Solidity format [[c0, c1], [c0, c1]]
const testProof = {
  a: snarkjsProof.a,
  b: [
    [snarkjsProof.b_raw[0][1], snarkjsProof.b_raw[0][0]], // Swap X coordinates
    [snarkjsProof.b_raw[1][1], snarkjsProof.b_raw[1][0]], // Swap Y coordinates
  ],
  c: snarkjsProof.c,
  pubSignals: snarkjsProof.pubSignals
};

async function main() {
  console.log('Direct RedeemVerifier Test');
  console.log('='.repeat(50));
  
  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  
  const verifier = new Contract(REDEEM_VERIFIER, VERIFIER_ABI, wallet);
  
  console.log('Testing verifyProof...');
  console.log('pA:', testProof.a);
  console.log('pB:', testProof.b);
  console.log('pC:', testProof.c);
  console.log('pubSignals:', testProof.pubSignals);
  
  try {
    const result = await verifier.verifyProof(
      testProof.a,
      testProof.b,
      testProof.c,
      testProof.pubSignals,
      { gasLimit: 5000000 }
    );
    console.log('\nVerify result:', result);
  } catch (e) {
    console.log('\nVerify failed:', e.message);
    // Try to get more details
    try {
      const data = verifier.interface.encodeFunctionData('verifyProof', [
        testProof.a,
        testProof.b,
        testProof.c,
        testProof.pubSignals,
      ]);
      const result = await provider.call({
        to: REDEEM_VERIFIER,
        data: data,
        gasLimit: 5000000,
      });
      console.log('Raw result:', result);
    } catch (e2) {
      console.log('Raw call error:', e2.message);
    }
  }
}

main().catch(console.error);
