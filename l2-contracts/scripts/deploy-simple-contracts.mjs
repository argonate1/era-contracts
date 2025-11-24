/**
 * Deploy only contracts with valid ZKsync bytecode format
 * PoseidonT3, NullifierRegistry, GhostVerifier
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
  if (remainder === 0) return bytecode;
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
  console.log('Ghost Protocol Simple Deploy');
  console.log('========================================\n');

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const network = await provider.getNetwork();
  const balance = await provider.getBalance(wallet.address);

  console.log('Network:', network.chainId.toString());
  console.log('Deployer:', wallet.address);
  console.log('Balance:', ethers.utils.formatEther(balance), 'ETH\n');

  // 1. Deploy PoseidonT3
  console.log('1. Deploying PoseidonT3...');
  const poseidonArtifact = loadZkArtifact('PoseidonT3');
  const PoseidonFactory = new ContractFactory(poseidonArtifact.abi, poseidonArtifact.bytecode, wallet, 'create');
  const poseidon = await PoseidonFactory.deploy();
  await poseidon.deployed();
  console.log('   PoseidonT3:', poseidon.address);

  // 2. Deploy NullifierRegistry
  console.log('\n2. Deploying NullifierRegistry...');
  const nullifierArtifact = loadZkArtifact('NullifierRegistry');
  const NullifierFactory = new ContractFactory(nullifierArtifact.abi, nullifierArtifact.bytecode, wallet, 'create');
  const nullifier = await NullifierFactory.deploy();
  await nullifier.deployed();
  console.log('   NullifierRegistry:', nullifier.address);

  // 3. Deploy GhostVerifier
  console.log('\n3. Deploying GhostVerifier...');
  const verifierArtifact = loadZkArtifact('GhostVerifier');
  const VerifierFactory = new ContractFactory(verifierArtifact.abi, verifierArtifact.bytecode, wallet, 'create');
  const verifier = await VerifierFactory.deploy();
  await verifier.deployed();
  console.log('   GhostVerifier:', verifier.address);

  console.log('\n========================================');
  console.log('Deployed Contracts:');
  console.log('========================================');
  console.log('PoseidonT3:       ', poseidon.address);
  console.log('NullifierRegistry:', nullifier.address);
  console.log('GhostVerifier:    ', verifier.address);
  console.log('\nNOTE: CommitmentTree and GhostERC20 have ELF bytecode');
  console.log('These need special deployment handling with library linking');

  // Save partial deployment
  const deployment = {
    network: network.chainId.toString(),
    deployer: wallet.address,
    timestamp: new Date().toISOString(),
    contracts: {
      poseidon: poseidon.address,
      nullifierRegistry: nullifier.address,
      verifier: verifier.address,
    },
    partial: true,
  };

  mkdirSync(join(__dirname, '..', 'deployments'), { recursive: true });
  const path = join(__dirname, '..', 'deployments', `ghost-partial-${network.chainId}.json`);
  writeFileSync(path, JSON.stringify(deployment, null, 2));
  console.log(`\nPartial deployment saved to: ${path}`);

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Deployment failed:', error);
    process.exit(1);
  });
