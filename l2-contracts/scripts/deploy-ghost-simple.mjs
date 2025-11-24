/**
 * Simple Ghost Protocol Deployment Script
 * Uses forge artifacts directly with ethers.js
 * No hardhat compilation required
 */

import { ethers } from 'ethers';
const { providers, Wallet, ContractFactory } = ethers;
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Configuration
const RPC_URL = 'http://127.0.0.1:3050';
const PRIVATE_KEY = '0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5';
const L2_ASSET_ROUTER = '0x0000000000000000000000000000000000010003';

// Load artifact from forge output
function loadArtifact(name) {
  const artifactPath = join(__dirname, '..', 'out', `${name}.sol`, `${name}.json`);
  const content = readFileSync(artifactPath, 'utf-8');
  const artifact = JSON.parse(content);
  return {
    abi: artifact.abi,
    bytecode: artifact.bytecode.object,
  };
}

async function main() {
  console.log('Starting Ghost Protocol deployment...\n');

  // Connect to provider
  const provider = new providers.JsonRpcProvider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const network = await provider.getNetwork();
  const balance = await provider.getBalance(wallet.address);

  console.log('Network:', network.chainId.toString());
  console.log('Deployer:', wallet.address);
  console.log('Balance:', balance.toString());
  console.log('');

  // 1. Deploy CommitmentTree
  console.log('1. Deploying CommitmentTree...');
  const commitmentTreeArtifact = loadArtifact('CommitmentTree');
  const CommitmentTreeFactory = new ContractFactory(
    commitmentTreeArtifact.abi,
    commitmentTreeArtifact.bytecode,
    wallet
  );
  const commitmentTree = await CommitmentTreeFactory.deploy();
  await commitmentTree.waitForDeployment();
  const commitmentTreeAddress = await commitmentTree.getAddress();
  console.log('   CommitmentTree deployed to:', commitmentTreeAddress);

  // 2. Deploy NullifierRegistry
  console.log('\n2. Deploying NullifierRegistry...');
  const nullifierRegistryArtifact = loadArtifact('NullifierRegistry');
  const NullifierRegistryFactory = new ContractFactory(
    nullifierRegistryArtifact.abi,
    nullifierRegistryArtifact.bytecode,
    wallet
  );
  const nullifierRegistry = await NullifierRegistryFactory.deploy();
  await nullifierRegistry.waitForDeployment();
  const nullifierRegistryAddress = await nullifierRegistry.getAddress();
  console.log('   NullifierRegistry deployed to:', nullifierRegistryAddress);

  // 3. Deploy GhostVerifier (with real Groth16 verification)
  console.log('\n3. Deploying GhostVerifier (with real ZK verification)...');
  const verifierArtifact = loadArtifact('GhostVerifier');
  const VerifierFactory = new ContractFactory(
    verifierArtifact.abi,
    verifierArtifact.bytecode,
    wallet
  );
  const verifier = await VerifierFactory.deploy();
  await verifier.waitForDeployment();
  const verifierAddress = await verifier.getAddress();
  console.log('   GhostVerifier deployed to:', verifierAddress);

  // 4. Deploy GhostERC20 Implementation
  console.log('\n4. Deploying GhostERC20 Implementation...');
  const ghostERC20Artifact = loadArtifact('GhostERC20');
  const GhostERC20Factory = new ContractFactory(
    ghostERC20Artifact.abi,
    ghostERC20Artifact.bytecode,
    wallet
  );
  const ghostERC20Impl = await GhostERC20Factory.deploy();
  await ghostERC20Impl.waitForDeployment();
  const ghostERC20ImplAddress = await ghostERC20Impl.getAddress();
  console.log('   GhostERC20 implementation deployed to:', ghostERC20ImplAddress);

  // 5. Deploy UpgradeableBeacon
  console.log('\n5. Deploying UpgradeableBeacon...');
  const beaconArtifact = loadArtifact('UpgradeableBeacon');
  const BeaconFactory = new ContractFactory(
    beaconArtifact.abi,
    beaconArtifact.bytecode,
    wallet
  );
  const beacon = await BeaconFactory.deploy(ghostERC20ImplAddress, wallet.address);
  await beacon.waitForDeployment();
  const beaconAddress = await beacon.getAddress();
  console.log('   UpgradeableBeacon deployed to:', beaconAddress);

  // 6. Deploy GhostNativeTokenVault
  console.log('\n6. Deploying GhostNativeTokenVault...');
  const ghostNTVArtifact = loadArtifact('GhostNativeTokenVault');
  const GhostNTVFactory = new ContractFactory(
    ghostNTVArtifact.abi,
    ghostNTVArtifact.bytecode,
    wallet
  );
  const ghostNTV = await GhostNTVFactory.deploy();
  await ghostNTV.waitForDeployment();
  const ghostNTVAddress = await ghostNTV.getAddress();
  console.log('   GhostNativeTokenVault deployed to:', ghostNTVAddress);

  // 7. Initialize GhostNativeTokenVault
  console.log('\n7. Initializing GhostNativeTokenVault...');
  const initTx = await ghostNTV.initialize(
    network.chainId,
    wallet.address,
    commitmentTreeAddress,
    nullifierRegistryAddress,
    verifierAddress,
    beaconAddress,
    L2_ASSET_ROUTER
  );
  await initTx.wait();
  console.log('   GhostNativeTokenVault initialized');

  // 8. Authorize contracts
  console.log('\n8. Setting up authorizations...');

  const authTreeTx = await commitmentTree.authorizeInserter(ghostNTVAddress);
  await authTreeTx.wait();
  console.log('   Authorized GhostNTV to insert commitments');

  const authNullTx = await nullifierRegistry.authorizeMarker(ghostNTVAddress);
  await authNullTx.wait();
  console.log('   Authorized GhostNTV to mark nullifiers');

  // 9. Create a test GhostERC20 token
  console.log('\n9. Creating test Ghost USDC token...');
  const testAssetId = '0x' + Buffer.from('test-usdc').toString('hex').padStart(64, '0');
  const testOriginToken = '0xA0B86a33e6441b8dE7FBC53b9a7d45B2E3d8b3A6'; // Mock L1 USDC

  const createTokenTx = await ghostNTV.createGhostToken(
    testAssetId,
    testOriginToken,
    'USD Coin',
    'USDC',
    6
  );
  const receipt = await createTokenTx.wait();

  // Find the ghost token address from events
  let ghostTokenAddress = '';
  for (const log of receipt.logs) {
    try {
      const parsed = ghostNTV.interface.parseLog(log);
      if (parsed?.name === 'GhostTokenCreated') {
        ghostTokenAddress = parsed.args.ghostToken;
        break;
      }
    } catch (e) {
      // Skip non-matching logs
    }
  }

  if (!ghostTokenAddress) {
    // Try getting from the NTV
    ghostTokenAddress = await ghostNTV.ghostTokens(testAssetId);
  }
  console.log('   Ghost USDC token created at:', ghostTokenAddress);

  // Summary
  console.log('\n========================================');
  console.log('Ghost Protocol Deployment Complete!');
  console.log('========================================');
  console.log('CommitmentTree:       ', commitmentTreeAddress);
  console.log('NullifierRegistry:    ', nullifierRegistryAddress);
  console.log('GhostVerifier:        ', verifierAddress);
  console.log('GhostERC20 Beacon:    ', beaconAddress);
  console.log('GhostNativeTokenVault:', ghostNTVAddress);
  console.log('Ghost USDC Token:     ', ghostTokenAddress);
  console.log('========================================');
  console.log('\n✅ Using REAL Groth16 ZK proof verification!');
  console.log('   All redemptions require valid ZK proofs');

  // Save deployment
  const deployment = {
    network: network.chainId.toString(),
    deployer: wallet.address,
    timestamp: new Date().toISOString(),
    contracts: {
      commitmentTree: commitmentTreeAddress,
      nullifierRegistry: nullifierRegistryAddress,
      verifier: verifierAddress,
      ghostERC20Beacon: beaconAddress,
      ghostNativeTokenVault: ghostNTVAddress,
      ghostUSDC: ghostTokenAddress,
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
VITE_GHOST_NTV_ADDRESS=${ghostNTVAddress}
`;
  writeFileSync(uiEnvPath, envContent);
  console.log(`UI .env updated with new contract address: ${ghostTokenAddress}`);

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
