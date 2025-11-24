/**
 * Deploy Ghost Protocol with ProductionVerifier
 * PoseidonT3 and NullifierRegistry are already deployed
 */

import { Provider, Wallet, ContractFactory } from 'zksync-ethers';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { ethers } from 'ethers';

const __dirname = dirname(fileURLToPath(import.meta.url));

const RPC_URL = 'http://127.0.0.1:3050';
const PRIVATE_KEY = '0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5';

// Already deployed contracts
const POSEIDON_ADDRESS = '0x34F6363a451118ba59fEF66ba0b89142a0CAB417';
const NULLIFIER_ADDRESS = '0xE485312215126613a5e8B8f1d8880919E6884029';

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

  // Check for ELF format (0x7f454c46)
  if (bytecode.startsWith('7f454c46') || bytecode.startsWith('0x7f454c46')) {
    throw new Error(`${name} has ELF format bytecode - needs library linking`);
  }

  return {
    abi: artifact.abi,
    bytecode: padBytecode(bytecode.startsWith('0x') ? bytecode : '0x' + bytecode),
  };
}

async function main() {
  console.log('========================================');
  console.log('Ghost Protocol Deployment');
  console.log('========================================\n');

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const network = await provider.getNetwork();
  const balance = await provider.getBalance(wallet.address);

  console.log('Network:', network.chainId.toString());
  console.log('Deployer:', wallet.address);
  console.log('Balance:', ethers.utils.formatEther(balance), 'ETH\n');

  console.log('Already deployed:');
  console.log('  PoseidonT3:       ', POSEIDON_ADDRESS);
  console.log('  NullifierRegistry:', NULLIFIER_ADDRESS);

  // 1. Deploy TestVerifier (simple verifier without nested deployments)
  console.log('\n1. Deploying TestVerifier...');
  const verifierArtifact = loadZkArtifact('TestVerifier');
  console.log('   Bytecode prefix:', verifierArtifact.bytecode.slice(0, 40));
  const VerifierFactory = new ContractFactory(verifierArtifact.abi, verifierArtifact.bytecode, wallet, 'create');
  const verifier = await VerifierFactory.deploy({
    gasLimit: 50000000,
    customData: {
      gasPerPubdata: 800,
    },
  });
  await verifier.deployed();
  const verifierAddress = verifier.address;
  console.log('   TestVerifier deployed to:', verifierAddress);

  // Verify deployment
  const verifierCode = await provider.getCode(verifierAddress);
  console.log('   Code length:', verifierCode.length, 'chars');

  console.log('\n========================================');
  console.log('Deployed Contracts:');
  console.log('========================================');
  console.log('PoseidonT3:        ', POSEIDON_ADDRESS);
  console.log('NullifierRegistry: ', NULLIFIER_ADDRESS);
  console.log('TestVerifier:      ', verifierAddress);

  console.log('\nNOTE: CommitmentTree and GhostERC20 have ELF bytecode');
  console.log('These contracts need different deployment approach.');

  // Save deployment
  const deployment = {
    network: network.chainId.toString(),
    deployer: wallet.address,
    timestamp: new Date().toISOString(),
    contracts: {
      poseidon: POSEIDON_ADDRESS,
      nullifierRegistry: NULLIFIER_ADDRESS,
      verifier: verifierAddress,
    },
    note: 'CommitmentTree and GhostERC20 pending',
  };

  mkdirSync(join(__dirname, '..', 'deployments'), { recursive: true });
  const deploymentPath = join(__dirname, '..', 'deployments', `ghost-partial-${network.chainId}.json`);
  writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment saved to: ${deploymentPath}`);

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Deployment failed:', error);
    process.exit(1);
  });
