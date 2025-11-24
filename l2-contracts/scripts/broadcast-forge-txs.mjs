/**
 * Broadcast forge script transactions to ZKsync Era
 * Reads from forge broadcast output and sends using zksync-ethers
 */

import { Provider, Wallet } from 'zksync-ethers';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { ethers } from 'ethers';

const __dirname = dirname(fileURLToPath(import.meta.url));

// Configuration
const RPC_URL = 'http://127.0.0.1:3050';
const PRIVATE_KEY = '0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5';

async function main() {
  console.log('========================================');
  console.log('Broadcasting Forge Script Transactions');
  console.log('========================================\n');

  // Load broadcast file
  const broadcastPath = join(__dirname, '..', 'broadcast', 'DeployGhostRealZK.s.sol', '271', 'run-latest.json');
  const broadcastContent = readFileSync(broadcastPath, 'utf-8');
  const broadcast = JSON.parse(broadcastContent);

  // Connect to ZKsync Era
  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  console.log('Deployer:', wallet.address);
  const balance = await provider.getBalance(wallet.address);
  console.log('Balance:', ethers.utils.formatEther(balance), 'ETH');

  let currentNonce = await provider.getTransactionCount(wallet.address);
  console.log('Starting nonce:', currentNonce);

  const deployedContracts = {};

  for (let i = 0; i < broadcast.transactions.length; i++) {
    const tx = broadcast.transactions[i];
    const txData = tx.transaction;
    const zkData = txData.zksync;

    console.log(`\n--- Transaction ${i + 1}/${broadcast.transactions.length} ---`);

    // Skip if not a CREATE deployment
    if (txData.to !== '0x0000000000000000000000000000000000008006') {
      console.log('Non-deploy transaction, checking type...');
      console.log('To:', txData.to);
    }

    try {
      // Prepare ZKsync transaction
      const zkTx = {
        type: 113, // EIP-712 transaction
        nonce: currentNonce,
        from: wallet.address,
        to: txData.to,
        data: txData.input,
        chainId: 271,
        gasLimit: zkData.gasLimit || '0x1000000', // High gas limit
        maxFeePerGas: ethers.utils.parseUnits('0.25', 'gwei'),
        maxPriorityFeePerGas: ethers.utils.parseUnits('0.25', 'gwei'),
        customData: {
          gasPerPubdata: zkData.gasPerPubdataByteLimit || '800',
          factoryDeps: zkData.factoryDeps || [],
        },
      };

      console.log('Sending transaction...');
      const response = await wallet.sendTransaction(zkTx);
      console.log('Tx hash:', response.hash);

      const receipt = await response.wait();
      console.log('Status:', receipt.status === 1 ? 'SUCCESS' : 'FAILED');

      // Track deployed contracts
      if (tx.contractAddress) {
        const name = tx.contractName || `Contract_${i}`;
        deployedContracts[name] = tx.contractAddress;
        console.log('Contract deployed at:', tx.contractAddress);
      }

      currentNonce++;
    } catch (err) {
      console.error('Transaction failed:', err.message);
      // Continue with next transaction
    }
  }

  console.log('\n========================================');
  console.log('Broadcast Complete!');
  console.log('========================================');
  console.log('Deployed contracts:', deployedContracts);

  // Save deployment addresses
  const deployment = {
    network: '271',
    deployer: wallet.address,
    timestamp: new Date().toISOString(),
    contracts: deployedContracts,
  };

  mkdirSync(join(__dirname, '..', 'deployments'), { recursive: true });
  const deploymentPath = join(__dirname, '..', 'deployments', 'ghost-271.json');
  writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment saved to: ${deploymentPath}`);

  return deployment;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Broadcast failed:', error);
    process.exit(1);
  });
