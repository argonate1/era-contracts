/**
 * Update Ghost Protocol verifier with new verification key
 *
 * This script deploys a new RedeemVerifierWorking (with updated VK) and
 * GhostVerifierProxy, then updates the TestGhostERC20 to use the new verifier.
 *
 * The verification key was updated to match the new circuit that uses
 * the Tornado Cash random nullifier pattern (no leafIndex in circuit).
 */

import { Wallet, Provider, ContractFactory, Contract } from "zksync-ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const PRIVATE_KEY = process.env.WALLET_PRIVATE_KEY || "0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c";
const RPC_URL = process.env.ZKSYNC_RPC_URL || "http://127.0.0.1:3150";

// Existing deployed contracts
const GHOST_TOKEN_ADDRESS = "0x2a1aaee151070ea12B69044bfFEF51E3FE12048A";
const PARTIAL_REDEEM_VERIFIER_ADDRESS = "0xc925014acF9a9A80aD7740D3dE5B88cCaBb86981";

async function loadArtifact(contractName: string, subdir?: string): Promise<{abi: any, bytecode: string}> {
  const basePath = path.join(__dirname, '../zkout');
  const paths = [
    path.join(basePath, subdir || '', `${contractName}.sol`, `${contractName}.json`),
    path.join(basePath, `${contractName}.sol`, `${contractName}.json`),
    path.join(basePath, 'verifiers', `${contractName}.sol`, `${contractName}.json`),
  ];

  let artifactPath: string | null = null;
  for (const p of paths) {
    if (fs.existsSync(p)) {
      artifactPath = p;
      break;
    }
  }

  if (!artifactPath) {
    throw new Error(`Artifact not found for ${contractName}. Run 'forge build --zksync' first.`);
  }
  console.log(`  Found artifact: ${artifactPath}`);

  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  let bytecode = artifact.bytecode.object;

  const cleanBytecode = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
  const bytesLength = cleanBytecode.length / 2;
  const remainder = bytesLength % 32;
  if (remainder !== 0) {
    const paddingBytes = 32 - remainder;
    bytecode = cleanBytecode + '00'.repeat(paddingBytes);
    console.log(`  Padded bytecode by ${paddingBytes} bytes for ZKsync compatibility`);
  }

  return {
    abi: artifact.abi,
    bytecode: '0x' + (bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode)
  };
}

async function deployContract(
  wallet: Wallet,
  name: string,
  args: any[] = [],
  gasLimit?: bigint,
  subdir?: string
): Promise<string> {
  console.log(`\nDeploying ${name}...`);

  const artifact = await loadArtifact(name, subdir);

  const factory = new ContractFactory(
    artifact.abi,
    artifact.bytecode,
    wallet,
    "create"
  );

  const deployTx = await factory.getDeployTransaction(...args);
  if (gasLimit) {
    (deployTx as any).gasLimit = gasLimit;
  }

  const sentTx = await wallet.sendTransaction(deployTx);
  console.log(`  Transaction hash: ${sentTx.hash}`);

  const receipt = await sentTx.wait();
  const address = receipt.contractAddress!;
  console.log(`  Deployed to: ${address}`);

  const code = await wallet.provider!.getCode(address);
  if (code.length <= 2) {
    throw new Error(`Contract deployment failed - no code at ${address}`);
  }

  return address;
}

async function main() {
  console.log("=".repeat(60));
  console.log("Ghost Protocol - Verifier Update");
  console.log("=".repeat(60));
  console.log("\nUpdating verifier with new verification key that matches");
  console.log("the Tornado Cash random nullifier circuit (no leafIndex).\n");

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const deployer = await wallet.getAddress();
  console.log(`Deployer: ${deployer}`);

  const balance = await provider.getBalance(deployer);
  console.log(`Balance: ${ethers.utils.formatEther(balance)} ETH`);

  const network = await provider.getNetwork();
  console.log(`Chain ID: ${network.chainId}`);

  try {
    // Step 1: Deploy new RedeemVerifierWorking with updated VK
    console.log("\n" + "-".repeat(40));
    console.log("Step 1: Deploy RedeemVerifierWorking (new VK)");
    console.log("-".repeat(40));
    const newRedeemVerifier = await deployContract(
      wallet,
      "RedeemVerifierWorking",
      [],
      BigInt(30000000),
      "verifiers"
    );

    // Step 2: Deploy new GhostVerifierProxy
    console.log("\n" + "-".repeat(40));
    console.log("Step 2: Deploy GhostVerifierProxy");
    console.log("-".repeat(40));
    console.log(`  Using RedeemVerifier: ${newRedeemVerifier}`);
    console.log(`  Using PartialRedeemVerifier: ${PARTIAL_REDEEM_VERIFIER_ADDRESS}`);

    const newVerifierProxy = await deployContract(
      wallet,
      "GhostVerifierProxy",
      [newRedeemVerifier, PARTIAL_REDEEM_VERIFIER_ADDRESS],
      BigInt(30000000),
      "verifiers"
    );

    // Step 3: Update TestGhostERC20 to use new verifier
    console.log("\n" + "-".repeat(40));
    console.log("Step 3: Update TestGhostERC20 verifier");
    console.log("-".repeat(40));

    // Load TestGhostERC20 ABI
    const tokenArtifact = await loadArtifact("TestGhostERC20", "test");
    const token = new Contract(
      GHOST_TOKEN_ADDRESS,
      tokenArtifact.abi,
      wallet
    );

    console.log(`  Calling setVerifier(${newVerifierProxy})...`);
    const tx = await token.setVerifier(newVerifierProxy);
    console.log(`  Transaction hash: ${tx.hash}`);
    await tx.wait();
    console.log(`  Verifier updated successfully!`);

    // Verify the update
    const currentVerifier = await token.verifier();
    console.log(`  Current verifier: ${currentVerifier}`);

    if (currentVerifier.toLowerCase() !== newVerifierProxy.toLowerCase()) {
      throw new Error("Verifier update verification failed!");
    }

    console.log("\n" + "=".repeat(60));
    console.log("VERIFIER UPDATE COMPLETE");
    console.log("=".repeat(60));
    console.log("\nNew Deployed Contracts:");
    console.log(`  RedeemVerifierWorking: ${newRedeemVerifier}`);
    console.log(`  GhostVerifierProxy: ${newVerifierProxy}`);
    console.log("\nUpdated .env value:");
    console.log(`VITE_VERIFIER_PROXY_ADDRESS=${newVerifierProxy}`);
    console.log("\nYou can now test the redeem flow in the UI!");

  } catch (error) {
    console.error("\n❌ Update failed:", error);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
