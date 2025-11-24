/**
 * Deploy complete Ghost Protocol test stack to ZKsync Era
 * Uses test contracts with keccak256 instead of Poseidon
 */

import { Provider, Wallet, ContractFactory } from 'zksync-ethers';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { ethers } from 'ethers';

const __dirname = dirname(fileURLToPath(import.meta.url));

const RPC_URL = 'http://127.0.0.1:3050';
const PRIVATE_KEY = '0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5';

function padBytecode(bytecode) {
  const hex = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
  const byteLength = hex.length / 2;
  const remainder = byteLength % 32;
  if (remainder === 0) return bytecode.startsWith('0x') ? bytecode : '0x' + hex;
  const paddingBytes = 32 - remainder;
  return (bytecode.startsWith('0x') ? bytecode : '0x' + hex) + '00'.repeat(paddingBytes);
}

function loadZkArtifact(name, subdir = null) {
  const path = subdir
    ? join(__dirname, '..', 'zkout', subdir, `${name}.json`)
    : join(__dirname, '..', 'zkout', `${name}.sol`, `${name}.json`);
  const content = readFileSync(path, 'utf-8');
  const artifact = JSON.parse(content);
  const bytecode = artifact.bytecode.object;

  return {
    abi: artifact.abi,
    bytecode: padBytecode(bytecode.startsWith('0x') ? bytecode : '0x' + bytecode),
  };
}

async function main() {
  console.log('========================================');
  console.log('Ghost Protocol Test Deployment (ZKsync)');
  console.log('========================================\n');

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const network = await provider.getNetwork();
  const balance = await provider.getBalance(wallet.address);

  console.log('Network:', network.chainId.toString());
  console.log('Deployer:', wallet.address);
  console.log('Balance:', ethers.utils.formatEther(balance), 'ETH\n');

  const deployOptions = {
    gasLimit: 50000000,
    customData: { gasPerPubdata: 800 },
  };

  // 1. Deploy NullifierRegistry
  console.log('1. Deploying NullifierRegistry...');
  const nullifierArtifact = loadZkArtifact('NullifierRegistry');
  const NullifierFactory = new ContractFactory(nullifierArtifact.abi, nullifierArtifact.bytecode, wallet, 'create');
  const nullifier = await NullifierFactory.deploy(deployOptions);
  await nullifier.deployed();
  console.log('   NullifierRegistry:', nullifier.address);

  // 2. Deploy TestCommitmentTree
  console.log('\n2. Deploying TestCommitmentTree...');
  const treeArtifact = loadZkArtifact('TestCommitmentTree');
  const TreeFactory = new ContractFactory(treeArtifact.abi, treeArtifact.bytecode, wallet, 'create');
  const tree = await TreeFactory.deploy(deployOptions);
  await tree.deployed();
  console.log('   TestCommitmentTree:', tree.address);

  // 3. Deploy TestVerifier
  console.log('\n3. Deploying TestVerifier...');
  const verifierArtifact = loadZkArtifact('TestVerifier');
  const VerifierFactory = new ContractFactory(verifierArtifact.abi, verifierArtifact.bytecode, wallet, 'create');
  const verifier = await VerifierFactory.deploy(deployOptions);
  await verifier.deployed();
  console.log('   TestVerifier:', verifier.address);

  // 4. Deploy TestGhostERC20
  console.log('\n4. Deploying TestGhostERC20...');
  const tokenArtifact = loadZkArtifact('TestGhostERC20');
  const TokenFactory = new ContractFactory(tokenArtifact.abi, tokenArtifact.bytecode, wallet, 'create');
  const token = await TokenFactory.deploy(deployOptions);
  await token.deployed();
  console.log('   TestGhostERC20:', token.address);

  // 5. Initialize TestGhostERC20
  console.log('\n5. Initializing TestGhostERC20...');
  const TEST_ASSET_ID = ethers.utils.keccak256(ethers.utils.toUtf8Bytes('TEST_ASSET'));
  const ORIGIN_TOKEN = '0x0000000000000000000000000000000000001234';
  const initTx = await token.initialize(
    TEST_ASSET_ID,
    ORIGIN_TOKEN,
    'Ghost Test Token',
    'gTEST',
    18,
    tree.address,
    nullifier.address,
    verifier.address,
    deployOptions
  );
  await initTx.wait();
  console.log('   Initialized with tree, nullifier, and verifier');

  // 6. Authorize token to insert commitments
  console.log('\n6. Setting authorizations...');
  const authTreeTx = await tree.authorizeInserter(token.address, deployOptions);
  await authTreeTx.wait();
  console.log('   Authorized token to insert commitments');

  const authNullTx = await nullifier.authorizeMarker(token.address, deployOptions);
  await authNullTx.wait();
  console.log('   Authorized token to mark nullifiers');

  // 7. Mint test tokens
  console.log('\n7. Minting test tokens...');
  const mintTx = await token.bridgeMint(wallet.address, ethers.utils.parseEther('10000'), deployOptions);
  await mintTx.wait();
  console.log('   Minted 10,000 gTEST to:', wallet.address);

  // Summary
  console.log('\n========================================');
  console.log('Ghost Protocol Test Deployed!');
  console.log('========================================');
  console.log('NullifierRegistry: ', nullifier.address);
  console.log('TestCommitmentTree:', tree.address);
  console.log('TestVerifier:      ', verifier.address);
  console.log('TestGhostERC20:    ', token.address);
  console.log('========================================');
  console.log('\nTEST MODE: Using keccak256 hash and mock verifier');

  // Save deployment
  const deployment = {
    network: network.chainId.toString(),
    deployer: wallet.address,
    timestamp: new Date().toISOString(),
    contracts: {
      nullifierRegistry: nullifier.address,
      commitmentTree: tree.address,
      verifier: verifier.address,
      ghostToken: token.address,
    },
    testMode: true,
  };

  mkdirSync(join(__dirname, '..', 'deployments'), { recursive: true });
  const deploymentPath = join(__dirname, '..', 'deployments', `ghost-test-${network.chainId}.json`);
  writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment saved to: ${deploymentPath}`);

  // Update UI .env
  try {
    const uiEnvPath = join(__dirname, '..', '..', '..', 'sdk', 'ghost-ui', '.env');
    const envContent = `VITE_GHOST_TOKEN_ADDRESS=${token.address}
VITE_COMMITMENT_TREE_ADDRESS=${tree.address}
VITE_NULLIFIER_REGISTRY_ADDRESS=${nullifier.address}
VITE_VERIFIER_ADDRESS=${verifier.address}
VITE_TEST_MODE=true
`;
    writeFileSync(uiEnvPath, envContent);
    console.log('UI .env updated with new contract addresses');
  } catch (e) {
    console.log('Note: Could not update UI .env:', e.message);
  }

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Deployment failed:', error);
    process.exit(1);
  });
