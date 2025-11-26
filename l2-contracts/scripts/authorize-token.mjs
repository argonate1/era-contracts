/**
 * Authorize the new TestGhostERC20 on the CommitmentTree
 */

import { Provider, Wallet, Contract } from 'zksync-ethers';

const CONFIG = {
  RPC_URL: 'http://127.0.0.1:3150',
  PRIVATE_KEY: '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c',

  // Commitment Tree address
  COMMITMENT_TREE: '0x456e224ADe45E4C4809F89D03C92Df65165f86CA',

  // New TestGhostERC20 v4 token to authorize
  NEW_TOKEN: '0xE8900F0b1ce38220C5B93d1eb1D0C9b51BC51973',
};

const COMMITMENT_TREE_ABI = [
  'function authorizeInserter(address inserter) external',
  'function authorizedInserters(address) view returns (bool)',
  'function owner() view returns (address)',
];

async function main() {
  console.log('='.repeat(60));
  console.log('Authorizing Token on CommitmentTree');
  console.log('='.repeat(60));

  const provider = new Provider(CONFIG.RPC_URL);
  const wallet = new Wallet(CONFIG.PRIVATE_KEY, provider);

  console.log('\nWallet:', wallet.address);
  console.log('CommitmentTree:', CONFIG.COMMITMENT_TREE);
  console.log('Token to authorize:', CONFIG.NEW_TOKEN);

  const commitmentTree = new Contract(CONFIG.COMMITMENT_TREE, COMMITMENT_TREE_ABI, wallet);

  // Check owner
  const owner = await commitmentTree.owner();
  console.log('\nTree owner:', owner);

  if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
    console.log('ERROR: Wallet is not the owner!');
    return;
  }
  console.log('Wallet IS the owner - can authorize');

  // Check current authorization status
  const isAuthorized = await commitmentTree.authorizedInserters(CONFIG.NEW_TOKEN);
  console.log('\nCurrent authorization status:', isAuthorized);

  if (isAuthorized) {
    console.log('Token is already authorized!');
    return;
  }

  // Authorize the token
  console.log('\nAuthorizing token...');
  const tx = await commitmentTree.authorizeInserter(CONFIG.NEW_TOKEN);
  console.log('Transaction hash:', tx.hash);

  await tx.wait();
  console.log('Transaction confirmed!');

  // Verify authorization
  const isNowAuthorized = await commitmentTree.authorizedInserters(CONFIG.NEW_TOKEN);
  console.log('\nNew authorization status:', isNowAuthorized);

  if (isNowAuthorized) {
    console.log('\n' + '='.repeat(60));
    console.log('SUCCESS! Token is now authorized on CommitmentTree');
    console.log('='.repeat(60));
  } else {
    console.log('\nWARNING: Authorization may have failed');
  }
}

main().catch(console.error);
