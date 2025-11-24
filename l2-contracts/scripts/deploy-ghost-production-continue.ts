/**
 * Continue Ghost Protocol production deployment from CommitmentTree
 *
 * Run after deploy-ghost-production.ts fails at CommitmentTree
 */

import { Wallet, Provider, ContractFactory, Contract } from "zksync-ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const PRIVATE_KEY = process.env.WALLET_PRIVATE_KEY || "0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5";
const RPC_URL = process.env.ZKSYNC_RPC_URL || "http://127.0.0.1:3050";

// Already deployed contracts
const VERIFIER_ADDRESS = "0x6D1658Bff8505c99b333734b31d6E0708472De5A";
const NULLIFIER_REGISTRY_ADDRESS = "0x824A58f516F5a0784EB9265AC00E1a46ada5CFd8";

async function loadArtifact(contractName: string): Promise<{abi: any, bytecode: string}> {
  const artifactPath = path.join(
    __dirname,
    `../zkout/${contractName}.sol/${contractName}.json`
  );

  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found: ${artifactPath}. Run 'forge build --zksync' first.`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  let bytecode = artifact.bytecode.object;

  // ZKsync requires bytecode length to be divisible by 32 bytes
  const cleanBytecode = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
  const bytesLength = cleanBytecode.length / 2;
  const remainder = bytesLength % 32;
  if (remainder !== 0) {
    const paddingBytes = 32 - remainder;
    bytecode = cleanBytecode + '00'.repeat(paddingBytes);
    console.log(`  Padded ${contractName} bytecode by ${paddingBytes} bytes for ZKsync compatibility`);
  }

  return {
    abi: artifact.abi,
    bytecode: '0x' + (bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode)
  };
}

async function deployContract(
  wallet: Wallet,
  name: string,
  args: any[] = []
): Promise<string> {
  console.log(`\nDeploying ${name}...`);

  const artifact = await loadArtifact(name);

  const factory = new ContractFactory(
    artifact.abi,
    artifact.bytecode,
    wallet,
    "create"
  );

  const deployTx = await factory.getDeployTransaction(...args);
  const sentTx = await wallet.sendTransaction(deployTx);
  console.log(`  Transaction hash: ${sentTx.hash}`);

  const receipt = await sentTx.wait();
  const address = receipt.contractAddress!;
  console.log(`  Deployed to: ${address}`);

  return address;
}

async function main() {
  console.log("=".repeat(60));
  console.log("Ghost Protocol - Continue Deployment");
  console.log("=".repeat(60));

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const deployer = await wallet.getAddress();
  console.log(`Deployer: ${deployer}`);

  const balance = await provider.getBalance(deployer);
  console.log(`Balance: ${ethers.utils.formatEther(balance)} ETH`);

  const network = await provider.getNetwork();
  console.log(`Chain ID: ${network.chainId}`);

  console.log("\nUsing already deployed contracts:");
  console.log(`  GhostVerifierProxy: ${VERIFIER_ADDRESS}`);
  console.log(`  NullifierRegistry: ${NULLIFIER_REGISTRY_ADDRESS}`);

  const deployedContracts: Record<string, string> = {
    verifier: VERIFIER_ADDRESS,
    nullifierRegistry: NULLIFIER_REGISTRY_ADDRESS,
  };

  try {
    // Step 5: Deploy CommitmentTree
    console.log("\n" + "-".repeat(40));
    console.log("Step 5/6: Deploy CommitmentTree (Poseidon)");
    console.log("-".repeat(40));
    deployedContracts.commitmentTree = await deployContract(wallet, "CommitmentTree");

    // Step 6: Deploy GhostERC20
    console.log("\n" + "-".repeat(40));
    console.log("Step 6/6: Deploy GhostERC20");
    console.log("-".repeat(40));

    const tokenName = "Ghost Token";
    const tokenSymbol = "gTEST";
    const decimals = 18;

    deployedContracts.ghostToken = await deployContract(
      wallet,
      "GhostERC20",
      [
        tokenName,
        tokenSymbol,
        decimals,
        deployedContracts.verifier,
        deployedContracts.commitmentTree,
        deployedContracts.nullifierRegistry
      ]
    );

    // Configure authorizations
    console.log("\n" + "-".repeat(40));
    console.log("Configuring authorizations...");
    console.log("-".repeat(40));

    const commitmentTreeArtifact = await loadArtifact("CommitmentTree");
    const commitmentTree = new Contract(
      deployedContracts.commitmentTree,
      commitmentTreeArtifact.abi,
      wallet
    );

    const authTx = await commitmentTree.authorizeInserter(deployedContracts.ghostToken);
    await authTx.wait();
    console.log(`  CommitmentTree: authorized GhostERC20 as inserter`);

    const nullifierRegistryArtifact = await loadArtifact("NullifierRegistry");
    const nullifierRegistry = new Contract(
      deployedContracts.nullifierRegistry,
      nullifierRegistryArtifact.abi,
      wallet
    );

    const authTx2 = await nullifierRegistry.authorizeMarker(deployedContracts.ghostToken);
    await authTx2.wait();
    console.log(`  NullifierRegistry: authorized GhostERC20 as marker`);

    // Save deployment info
    const deploymentInfo = {
      network: network.chainId.toString(),
      deployer: deployer,
      timestamp: new Date().toISOString(),
      contracts: deployedContracts,
      testMode: false,
      hashFunction: "Poseidon"
    };

    const outputPath = path.join(__dirname, `../deployments/ghost-production-${network.chainId}.json`);
    const outputDir = path.dirname(outputPath);
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }
    fs.writeFileSync(outputPath, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n" + "=".repeat(60));
    console.log("DEPLOYMENT COMPLETE (Production - Poseidon)");
    console.log("=".repeat(60));
    console.log("\n📋 UI Environment Variables:");
    console.log(`VITE_GHOST_TOKEN_ADDRESS=${deployedContracts.ghostToken}`);
    console.log(`VITE_COMMITMENT_TREE_ADDRESS=${deployedContracts.commitmentTree}`);
    console.log(`VITE_NULLIFIER_REGISTRY_ADDRESS=${deployedContracts.nullifierRegistry}`);
    console.log(`VITE_VERIFIER_ADDRESS=${deployedContracts.verifier}`);
    console.log(`VITE_TEST_MODE=false`);

  } catch (error) {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
