/**
 * Deploy Groth16 Verifiers for Ghost Protocol
 *
 * Deploys:
 * 1. RedeemVerifier (Groth16 verifier for full redemptions)
 * 2. PartialRedeemVerifier (Groth16 verifier for partial redemptions)
 * 3. GhostVerifierProxy (wrapper that routes to correct verifier)
 * 4. TestGhostERC20 (Ghost token with test mint capability)
 *
 * Then initializes and authorizes TestGhostERC20
 */

import { Provider, Wallet, ContractFactory, Contract } from 'zksync-ethers';
import { readFileSync, writeFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { ethers } from 'ethers';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Configuration for Umbraline L2
const RPC_URL = 'http://127.0.0.1:3150';
const PRIVATE_KEY = '0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c';
const CHAIN_ID = 5447;

// Existing contracts to reuse
const COMMITMENT_TREE = '0x456e224ADe45E4C4809F89D03C92Df65165f86CA';
const NULLIFIER_REGISTRY = '0xbFaF8231ED01e2631AfFE7F5e3c6d85006B8b33F';

function padBytecode(bytecode) {
  const hex = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
  const byteLength = hex.length / 2;
  const remainder = byteLength % 32;
  if (remainder === 0) return bytecode.startsWith('0x') ? bytecode : '0x' + hex;
  const paddingBytes = 32 - remainder;
  return (bytecode.startsWith('0x') ? bytecode : '0x' + hex) + '00'.repeat(paddingBytes);
}

function loadArtifact(contractName) {
  const path = join(__dirname, '..', 'zkout', `${contractName}.sol`, `${contractName}.json`);
  const content = readFileSync(path, 'utf-8');
  const artifact = JSON.parse(content);
  const bytecode = padBytecode(
    artifact.bytecode.object.startsWith('0x')
      ? artifact.bytecode.object
      : '0x' + artifact.bytecode.object
  );
  return { abi: artifact.abi, bytecode };
}

async function deployContract(wallet, contractName, constructorArgs = []) {
  console.log(`\nDeploying ${contractName}...`);
  const { abi, bytecode } = loadArtifact(contractName);

  const factory = new ContractFactory(abi, bytecode, wallet, 'create');

  const deployOptions = {
    gasLimit: 10000000,
    customData: {
      gasPerPubdata: 800,
      factoryDeps: [],
    },
  };

  let contract;
  if (constructorArgs.length > 0) {
    contract = await factory.deploy(...constructorArgs, deployOptions);
  } else {
    contract = await factory.deploy(deployOptions);
  }

  await contract.deployed();
  console.log(`${contractName} deployed to: ${contract.address}`);

  return contract;
}

async function main() {
  console.log('='.repeat(60));
  console.log('Ghost Protocol - Groth16 Verifier Deployment');
  console.log('='.repeat(60));

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const balance = await provider.getBalance(wallet.address);
  console.log('\nDeployer:', wallet.address);
  console.log('Balance:', ethers.utils.formatEther(balance), 'ETH');
  console.log('Chain ID:', CHAIN_ID);

  // Verify connection
  const chainId = await provider.send('eth_chainId', []);
  console.log('Connected to chain:', parseInt(chainId, 16));

  const deployed = {
    timestamp: new Date().toISOString(),
    chainId: CHAIN_ID,
    deployer: wallet.address,
  };

  // Step 1: Deploy RedeemVerifierWorking (ZKsync-compatible with bytes memory allocation)
  const redeemVerifier = await deployContract(wallet, 'RedeemVerifierWorking');
  deployed.RedeemVerifierWorking = redeemVerifier.address;

  // Step 2: Deploy PartialRedeemVerifier
  const partialRedeemVerifier = await deployContract(wallet, 'PartialRedeemVerifier');
  deployed.PartialRedeemVerifier = partialRedeemVerifier.address;

  // Step 3: Deploy GhostVerifierProxy with both verifier addresses
  const ghostVerifierProxy = await deployContract(
    wallet,
    'GhostVerifierProxy',
    [redeemVerifier.address, partialRedeemVerifier.address]
  );
  deployed.GhostVerifierProxy = ghostVerifierProxy.address;

  // Step 4: Deploy TestGhostERC20
  const testGhostERC20 = await deployContract(wallet, 'TestGhostERC20');
  deployed.TestGhostERC20 = testGhostERC20.address;

  // Step 5: Initialize TestGhostERC20
  console.log('\nInitializing TestGhostERC20...');
  const testGhostArtifact = loadArtifact('TestGhostERC20');
  const testGhostContract = new Contract(testGhostERC20.address, testGhostArtifact.abi, wallet);

  const initTx = await testGhostContract.initialize(
    '0x0000000000000000000000000000000000000000000000000000000000000001', // l2BridgeAddress (placeholder)
    '0x0000000000000000000000000000000000000000', // l1Address (no L1 counterpart)
    'Ghost Test Token',
    'gTEST',
    18,
    COMMITMENT_TREE,
    NULLIFIER_REGISTRY,
    ghostVerifierProxy.address,
    { gasLimit: 5000000 }
  );
  await initTx.wait();
  console.log('TestGhostERC20 initialized');

  // Step 6: Authorize TestGhostERC20 as inserter in CommitmentTree
  console.log('\nAuthorizing TestGhostERC20 in CommitmentTree...');
  const commitmentTreeAbi = [
    'function authorizeInserter(address inserter) external',
    'function authorizedInserters(address) view returns (bool)'
  ];
  const commitmentTree = new Contract(COMMITMENT_TREE, commitmentTreeAbi, wallet);

  const authInserterTx = await commitmentTree.authorizeInserter(
    testGhostERC20.address,
    { gasLimit: 1000000 }
  );
  await authInserterTx.wait();
  console.log('TestGhostERC20 authorized as inserter');

  // Step 7: Authorize TestGhostERC20 as marker in NullifierRegistry
  console.log('\nAuthorizing TestGhostERC20 in NullifierRegistry...');
  const nullifierRegistryAbi = [
    'function authorizeMarker(address marker) external',
    'function authorizedMarkers(address) view returns (bool)'
  ];
  const nullifierRegistry = new Contract(NULLIFIER_REGISTRY, nullifierRegistryAbi, wallet);

  const authMarkerTx = await nullifierRegistry.authorizeMarker(
    testGhostERC20.address,
    { gasLimit: 1000000 }
  );
  await authMarkerTx.wait();
  console.log('TestGhostERC20 authorized as marker');

  // Save deployment info
  deployed.CommitmentTree = COMMITMENT_TREE;
  deployed.NullifierRegistry = NULLIFIER_REGISTRY;

  console.log('\n' + '='.repeat(60));
  console.log('Deployment Complete!');
  console.log('='.repeat(60));
  console.log('\nDeployed Contracts:');
  console.log(JSON.stringify(deployed, null, 2));

  // Save to deployment file
  const deploymentPath = join(__dirname, '..', 'deployments', `ghost-groth16-${CHAIN_ID}.json`);
  writeFileSync(deploymentPath, JSON.stringify({
    network: 'umbraline',
    chainId: CHAIN_ID,
    timestamp: deployed.timestamp,
    deploymentType: 'production-groth16',
    deployer: wallet.address,
    contracts: {
      RedeemVerifierWorking: deployed.RedeemVerifierWorking,
      PartialRedeemVerifier: deployed.PartialRedeemVerifier,
      GhostVerifierProxy: deployed.GhostVerifierProxy,
      CommitmentTree: COMMITMENT_TREE,
      NullifierRegistry: NULLIFIER_REGISTRY,
      TestGhostERC20: deployed.TestGhostERC20,
    },
    verified: {
      isTestContract: false,
      hashFunction: 'poseidon',
      zkProofSystem: 'groth16',
    },
  }, null, 2));
  console.log(`\nDeployment saved to: ${deploymentPath}`);

  // Output for .env update
  console.log('\n' + '='.repeat(60));
  console.log('Update sdk/ghost-ui/.env with:');
  console.log('='.repeat(60));
  console.log(`VITE_GHOST_TOKEN_ADDRESS=${deployed.TestGhostERC20}`);
  console.log(`VITE_COMMITMENT_TREE_ADDRESS=${COMMITMENT_TREE}`);
  console.log(`VITE_NULLIFIER_REGISTRY_ADDRESS=${NULLIFIER_REGISTRY}`);
  console.log(`VITE_VERIFIER_PROXY_ADDRESS=${deployed.GhostVerifierProxy}`);

  return deployed;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Deployment failed:', error.message || error);
    process.exit(1);
  });
