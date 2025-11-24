/**
 * Deploy GhostVerifier with explicit gas limit
 */

import { Provider, Wallet, ContractFactory } from 'zksync-ethers';
import { readFileSync } from 'fs';
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

async function main() {
  console.log('Deploying GhostVerifier...');

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const balance = await provider.getBalance(wallet.address);
  console.log('Deployer:', wallet.address);
  console.log('Balance:', ethers.utils.formatEther(balance), 'ETH');

  // Load artifact
  const path = join(__dirname, '..', 'zkout', 'GhostVerifier.sol', 'GhostVerifier.json');
  const content = readFileSync(path, 'utf-8');
  const artifact = JSON.parse(content);
  const bytecode = padBytecode(artifact.bytecode.object.startsWith('0x') ? artifact.bytecode.object : '0x' + artifact.bytecode.object);

  // Create factory with explicit deployment type
  const factory = new ContractFactory(artifact.abi, bytecode, wallet, 'create');

  // Deploy with explicit overrides
  const contract = await factory.deploy({
    gasLimit: 10000000, // High gas limit
    customData: {
      gasPerPubdata: 800,
      factoryDeps: [], // No factory deps needed
    },
  });

  await contract.deployed();
  console.log('GhostVerifier deployed to:', contract.address);

  // Verify deployment
  const code = await provider.getCode(contract.address);
  console.log('Code length:', code.length, 'bytes');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Failed:', error.message || error);
    process.exit(1);
  });
