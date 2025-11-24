/**
 * Mint Ghost tokens for testing
 *
 * This script mints gTEST tokens to a specified address using the deployer wallet
 * (which was set as the nativeTokenVault during deployment).
 *
 * Usage:
 *   npx ts-node scripts/mint-ghost-tokens.ts [recipient] [amount]
 *
 * Examples:
 *   npx ts-node scripts/mint-ghost-tokens.ts                                    # Mint 1000 to default test wallet
 *   npx ts-node scripts/mint-ghost-tokens.ts 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266  # Mint 1000 to specific address
 *   npx ts-node scripts/mint-ghost-tokens.ts 0xf39... 5000                       # Mint 5000 to specific address
 */

import { Wallet, Provider, Contract } from "zksync-ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

// Default configuration
// Rich wallet from ZKsync local node that was used for deployment (is the NTV)
const PRIVATE_KEY = process.env.WALLET_PRIVATE_KEY || "0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5";
const RPC_URL = process.env.ZKSYNC_RPC_URL || "http://127.0.0.1:3050";
const DEFAULT_RECIPIENT = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // Hardhat test wallet #0
const DEFAULT_AMOUNT = "1000"; // 1000 tokens

async function loadDeployment(): Promise<{ghostToken: string}> {
  const deploymentPath = path.join(__dirname, "../deployments/ghost-production-271.json");

  if (!fs.existsSync(deploymentPath)) {
    throw new Error(`Deployment file not found: ${deploymentPath}`);
  }

  const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
  return {
    ghostToken: deployment.contracts.ghostToken
  };
}

async function main() {
  // Parse arguments
  const args = process.argv.slice(2);
  const recipient = args[0] || DEFAULT_RECIPIENT;
  const amountStr = args[1] || DEFAULT_AMOUNT;
  const amount = ethers.utils.parseEther(amountStr);

  console.log("=".repeat(60));
  console.log("Ghost Token Faucet");
  console.log("=".repeat(60));
  console.log(`\nRPC URL: ${RPC_URL}`);
  console.log(`Recipient: ${recipient}`);
  console.log(`Amount: ${amountStr} gTEST`);

  // Setup provider and wallet
  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const deployer = await wallet.getAddress();
  console.log(`\nDeployer (NTV): ${deployer}`);

  // Load deployment addresses
  const { ghostToken } = await loadDeployment();
  console.log(`Ghost Token: ${ghostToken}`);

  // Create contract instance
  const ghostTokenABI = [
    "function bridgeMint(address _to, uint256 _amount) external",
    "function balanceOf(address account) view returns (uint256)",
    "function name() view returns (string)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function nativeTokenVault() view returns (address)"
  ];

  const contract = new Contract(ghostToken, ghostTokenABI, wallet);

  // Verify we are the NTV
  const ntv = await contract.nativeTokenVault();
  console.log(`\nNative Token Vault: ${ntv}`);

  if (ntv.toLowerCase() !== deployer.toLowerCase()) {
    throw new Error(`Deployer ${deployer} is not the NTV ${ntv}. Cannot mint tokens.`);
  }

  // Get token info
  const name = await contract.name();
  const symbol = await contract.symbol();
  console.log(`Token: ${name} (${symbol})`);

  // Check balance before
  const balanceBefore = await contract.balanceOf(recipient);
  console.log(`\nBalance before: ${ethers.utils.formatEther(balanceBefore)} ${symbol}`);

  // Mint tokens
  console.log(`\nMinting ${amountStr} ${symbol} to ${recipient}...`);
  const tx = await contract.bridgeMint(recipient, amount);
  console.log(`Transaction hash: ${tx.hash}`);
  await tx.wait();
  console.log("Transaction confirmed!");

  // Check balance after
  const balanceAfter = await contract.balanceOf(recipient);
  console.log(`Balance after: ${ethers.utils.formatEther(balanceAfter)} ${symbol}`);

  console.log("\n" + "=".repeat(60));
  console.log("SUCCESS! Tokens minted.");
  console.log("=".repeat(60));
}

main().catch((error) => {
  console.error("\nError:", error.message);
  process.exit(1);
});
