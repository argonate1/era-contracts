/**
 * Ghost Protocol Deployment Script for ZKsync Era
 * Uses zkout artifacts (ZKsync-compiled) with zksync-ethers v5
 */

import { Provider, Wallet, ContractFactory } from 'zksync-ethers';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { ethers } from 'ethers';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Configuration
const RPC_URL = 'http://127.0.0.1:3050';
const PRIVATE_KEY = '0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5';

// Pad bytecode to 32-byte boundary (required by zksync-ethers)
function padBytecode(bytecode) {
  // Remove 0x prefix if present
  const hex = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
  // Calculate bytes (2 hex chars = 1 byte)
  const byteLength = hex.length / 2;
  // Calculate padding needed to reach 32-byte boundary
  const remainder = byteLength % 32;
  if (remainder === 0) return bytecode;

  // Pad with zeros
  const paddingBytes = 32 - remainder;
  const paddingHex = '00'.repeat(paddingBytes);
  return bytecode.startsWith('0x') ? bytecode + paddingHex : '0x' + hex + paddingHex;
}

// Load artifact from zkout directory (ZKsync-compiled)
function loadZkArtifact(name, subdir = null) {
  const path = subdir
    ? join(__dirname, '..', 'zkout', `${subdir}`, `${name}.json`)
    : join(__dirname, '..', 'zkout', `${name}.sol`, `${name}.json`);
  const content = readFileSync(path, 'utf-8');
  const artifact = JSON.parse(content);
  return {
    abi: artifact.abi,
    bytecode: padBytecode(artifact.bytecode.object),
  };
}

async function main() {
  console.log('========================================');
  console.log('Ghost Protocol Deployment (ZKsync Era)');
  console.log('========================================\n');

  // Connect to ZKsync Era
  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const network = await provider.getNetwork();
  const balance = await provider.getBalance(wallet.address);

  console.log('Network:', network.chainId.toString());
  console.log('Deployer:', wallet.address);
  console.log('Balance:', ethers.utils.formatEther(balance), 'ETH\n');

  // Test asset configuration
  const TEST_ASSET_ID = ethers.utils.keccak256(ethers.utils.toUtf8Bytes('TEST_ASSET'));
  const ORIGIN_TOKEN = '0x0000000000000000000000000000000000001234';

  // 1. Deploy PoseidonT3 library first
  console.log('1. Deploying PoseidonT3 library...');
  const poseidonArtifact = loadZkArtifact('PoseidonT3');
  const PoseidonFactory = new ContractFactory(
    poseidonArtifact.abi,
    poseidonArtifact.bytecode,
    wallet,
    'create'
  );
  const poseidon = await PoseidonFactory.deploy();
  await poseidon.deployed();
  const poseidonAddress = poseidon.address;
  console.log('   PoseidonT3 deployed to:', poseidonAddress);

  // 2. Deploy CommitmentTree
  console.log('\n2. Deploying CommitmentTree...');
  const commitmentTreeArtifact = loadZkArtifact('CommitmentTree');
  const CommitmentTreeFactory = new ContractFactory(
    commitmentTreeArtifact.abi,
    commitmentTreeArtifact.bytecode,
    wallet,
    'create'
  );
  const commitmentTree = await CommitmentTreeFactory.deploy();
  await commitmentTree.deployed();
  const commitmentTreeAddress = commitmentTree.address;
  console.log('   CommitmentTree deployed to:', commitmentTreeAddress);

  // 3. Deploy NullifierRegistry
  console.log('\n3. Deploying NullifierRegistry...');
  const nullifierRegistryArtifact = loadZkArtifact('NullifierRegistry');
  const NullifierRegistryFactory = new ContractFactory(
    nullifierRegistryArtifact.abi,
    nullifierRegistryArtifact.bytecode,
    wallet,
    'create'
  );
  const nullifierRegistry = await NullifierRegistryFactory.deploy();
  await nullifierRegistry.deployed();
  const nullifierRegistryAddress = nullifierRegistry.address;
  console.log('   NullifierRegistry deployed to:', nullifierRegistryAddress);

  // 4. Deploy GhostVerifier (real Groth16 ZK verification)
  console.log('\n4. Deploying GhostVerifier (Real ZK)...');
  const verifierArtifact = loadZkArtifact('GhostVerifier');
  const VerifierFactory = new ContractFactory(
    verifierArtifact.abi,
    verifierArtifact.bytecode,
    wallet,
    'create'
  );
  const verifier = await VerifierFactory.deploy();
  await verifier.deployed();
  const verifierAddress = verifier.address;
  console.log('   GhostVerifier deployed to:', verifierAddress);

  // 5. Deploy GhostERC20Harness (test token)
  console.log('\n5. Deploying GhostERC20Harness...');
  const ghostTokenArtifact = loadZkArtifact('GhostERC20Harness', 'GhostERC20Harness.sol');
  const GhostTokenFactory = new ContractFactory(
    ghostTokenArtifact.abi,
    ghostTokenArtifact.bytecode,
    wallet,
    'create'
  );
  const ghostToken = await GhostTokenFactory.deploy();
  await ghostToken.deployed();
  const ghostTokenAddress = ghostToken.address;
  console.log('   GhostERC20Harness deployed to:', ghostTokenAddress);

  // 6. Initialize GhostERC20Harness
  console.log('\n6. Initializing GhostERC20Harness...');
  const initTx = await ghostToken.initialize(
    TEST_ASSET_ID,
    ORIGIN_TOKEN,
    'Ghost Test Token',
    'gTEST',
    18,
    commitmentTreeAddress,
    nullifierRegistryAddress,
    verifierAddress
  );
  await initTx.wait();
  console.log('   Initialized with:');
  console.log('   - CommitmentTree:', commitmentTreeAddress);
  console.log('   - NullifierRegistry:', nullifierRegistryAddress);
  console.log('   - GhostVerifier:', verifierAddress);

  // 7. Set authorizations
  console.log('\n7. Setting authorizations...');
  const authTreeTx = await commitmentTree.authorizeInserter(ghostTokenAddress);
  await authTreeTx.wait();
  console.log('   Authorized GhostToken to insert commitments');

  const authNullTx = await nullifierRegistry.authorizeMarker(ghostTokenAddress);
  await authNullTx.wait();
  console.log('   Authorized GhostToken to mark nullifiers');

  // 8. Mint test tokens
  console.log('\n8. Minting test tokens...');
  const mintTx = await ghostToken.bridgeMint(wallet.address, ethers.utils.parseEther('10000'));
  await mintTx.wait();
  console.log('   Minted 10,000 gTEST to:', wallet.address);

  // Summary
  console.log('\n========================================');
  console.log('Ghost Protocol Deployed!');
  console.log('========================================');
  console.log('PoseidonT3:        ', poseidonAddress);
  console.log('CommitmentTree:    ', commitmentTreeAddress);
  console.log('NullifierRegistry: ', nullifierRegistryAddress);
  console.log('GhostVerifier:     ', verifierAddress);
  console.log('GhostERC20:        ', ghostTokenAddress);
  console.log('========================================');
  console.log('\nUSING REAL GROTH16 ZK VERIFICATION');
  console.log('All redemptions require valid ZK proofs!');

  // Save deployment
  const deployment = {
    network: network.chainId.toString(),
    deployer: wallet.address,
    timestamp: new Date().toISOString(),
    contracts: {
      poseidon: poseidonAddress,
      commitmentTree: commitmentTreeAddress,
      nullifierRegistry: nullifierRegistryAddress,
      verifier: verifierAddress,
      ghostToken: ghostTokenAddress,
    },
    realZkVerification: true,
  };

  mkdirSync(join(__dirname, '..', 'deployments'), { recursive: true });
  const deploymentPath = join(__dirname, '..', 'deployments', `ghost-${network.chainId}.json`);
  writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment saved to: ${deploymentPath}`);

  // Update UI .env
  const uiEnvPath = join(__dirname, '..', '..', '..', 'sdk', 'ghost-ui', '.env');
  const envContent = `VITE_GHOST_TOKEN_ADDRESS=${ghostTokenAddress}
VITE_COMMITMENT_TREE_ADDRESS=${commitmentTreeAddress}
VITE_NULLIFIER_REGISTRY_ADDRESS=${nullifierRegistryAddress}
VITE_VERIFIER_ADDRESS=${verifierAddress}
`;
  writeFileSync(uiEnvPath, envContent);
  console.log(`UI .env updated with new contract addresses`);

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Deployment failed:', error);
    process.exit(1);
  });
