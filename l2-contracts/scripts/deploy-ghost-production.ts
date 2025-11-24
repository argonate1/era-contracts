/**
 * Deploy Ghost Protocol production contracts to ZKsync Era
 *
 * This script deploys contracts with Poseidon hash (production-ready).
 *
 * Deployment order (to avoid nested deployment issues on ZKsync):
 * 1. RedeemVerifier (standalone)
 * 2. PartialRedeemVerifier (standalone)
 * 3. GhostVerifierProxy (with verifier addresses)
 * 4. NullifierRegistry
 * 5. CommitmentTree (with Poseidon)
 * 6. GhostERC20
 */

import * as hre from "hardhat";
import { Wallet, Provider, ContractFactory, Contract } from "zksync-ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const PRIVATE_KEY = process.env.WALLET_PRIVATE_KEY || "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110";
const RPC_URL = process.env.ZKSYNC_RPC_URL || "http://127.0.0.1:3050";

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
  // Pad with zeros if needed
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
  args: any[] = [],
  factoryDeps: string[] = []
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

  // Add factoryDeps if any
  if (factoryDeps.length > 0) {
    (deployTx as any).customData = {
      factoryDeps: factoryDeps
    };
  }

  const sentTx = await wallet.sendTransaction(deployTx);
  console.log(`  Transaction hash: ${sentTx.hash}`);

  const receipt = await sentTx.wait();
  const address = receipt.contractAddress!;
  console.log(`  Deployed to: ${address}`);

  return address;
}

async function main() {
  console.log("=".repeat(60));
  console.log("Ghost Protocol Production Deployment (Poseidon)");
  console.log("=".repeat(60));
  console.log(`\nRPC URL: ${RPC_URL}`);

  // Setup provider and wallet
  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const deployer = await wallet.getAddress();
  console.log(`Deployer: ${deployer}`);

  const balance = await provider.getBalance(deployer);
  console.log(`Balance: ${ethers.utils.formatEther(balance)} ETH`);

  if (balance.lt(ethers.utils.parseEther("0.1"))) {
    throw new Error("Insufficient balance for deployment");
  }

  const network = await provider.getNetwork();
  console.log(`Chain ID: ${network.chainId}`);

  const deployedContracts: Record<string, string> = {};

  try {
    // Step 1: Deploy RedeemVerifier (standalone Groth16 verifier)
    console.log("\n" + "-".repeat(40));
    console.log("Step 1/6: Deploy RedeemVerifier");
    console.log("-".repeat(40));
    deployedContracts.redeemVerifier = await deployContract(wallet, "RedeemVerifier");

    // Step 2: Deploy PartialRedeemVerifier (standalone Groth16 verifier)
    console.log("\n" + "-".repeat(40));
    console.log("Step 2/6: Deploy PartialRedeemVerifier");
    console.log("-".repeat(40));
    deployedContracts.partialRedeemVerifier = await deployContract(wallet, "PartialRedeemVerifier");

    // Step 3: Deploy GhostVerifierProxy with pre-deployed verifier addresses
    console.log("\n" + "-".repeat(40));
    console.log("Step 3/6: Deploy GhostVerifierProxy");
    console.log("-".repeat(40));
    deployedContracts.verifier = await deployContract(
      wallet,
      "GhostVerifierProxy",
      [deployedContracts.redeemVerifier, deployedContracts.partialRedeemVerifier]
    );

    // Step 4: Deploy NullifierRegistry
    console.log("\n" + "-".repeat(40));
    console.log("Step 4/6: Deploy NullifierRegistry");
    console.log("-".repeat(40));
    deployedContracts.nullifierRegistry = await deployContract(wallet, "NullifierRegistry");

    // Step 5: Deploy CommitmentTree (uses Poseidon via GhostHash library)
    console.log("\n" + "-".repeat(40));
    console.log("Step 5/6: Deploy CommitmentTree (Poseidon)");
    console.log("-".repeat(40));
    deployedContracts.commitmentTree = await deployContract(wallet, "CommitmentTree");

    // Step 6: Deploy GhostERC20 (upgradeable pattern - deploy then initialize)
    console.log("\n" + "-".repeat(40));
    console.log("Step 6/6: Deploy GhostERC20");
    console.log("-".repeat(40));

    // Deploy with no constructor args (upgradeable contract)
    deployedContracts.ghostToken = await deployContract(wallet, "GhostERC20", []);

    // Initialize the contract
    console.log("  Initializing GhostERC20...");
    const ghostTokenArtifact = await loadArtifact("GhostERC20");
    const ghostToken = new Contract(
      deployedContracts.ghostToken,
      ghostTokenArtifact.abi,
      wallet
    );

    const assetId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ghost-test-token"));
    const originToken = wallet.address; // Use deployer as origin token for testing
    const tokenName = "Test Token";
    const tokenSymbol = "TEST";
    const decimals = 18;

    const initTx = await ghostToken.initialize(
      assetId,
      originToken,
      tokenName,
      tokenSymbol,
      decimals,
      deployedContracts.commitmentTree,
      deployedContracts.nullifierRegistry,
      deployedContracts.verifier
    );
    await initTx.wait();
    console.log(`  Initialized with name: Ghost ${tokenName}, symbol: g${tokenSymbol}`);

    // Configure authorizations
    console.log("\n" + "-".repeat(40));
    console.log("Configuring authorizations...");
    console.log("-".repeat(40));

    // Authorize GhostERC20 to insert commitments
    const commitmentTreeArtifact = await loadArtifact("CommitmentTree");
    const commitmentTree = new Contract(
      deployedContracts.commitmentTree,
      commitmentTreeArtifact.abi,
      wallet
    );

    const authTx = await commitmentTree.authorizeInserter(deployedContracts.ghostToken);
    await authTx.wait();
    console.log(`  CommitmentTree: authorized GhostERC20 as inserter`);

    // Authorize GhostERC20 to mark nullifiers
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
    console.log(`\nDeployment info saved to: ${outputPath}`);

    // Print summary
    console.log("\n" + "=".repeat(60));
    console.log("DEPLOYMENT COMPLETE (Production - Poseidon)");
    console.log("=".repeat(60));
    console.log("\nContract Addresses:");
    console.log(`  RedeemVerifier:        ${deployedContracts.redeemVerifier}`);
    console.log(`  PartialRedeemVerifier: ${deployedContracts.partialRedeemVerifier}`);
    console.log(`  GhostVerifierProxy:    ${deployedContracts.verifier}`);
    console.log(`  NullifierRegistry:     ${deployedContracts.nullifierRegistry}`);
    console.log(`  CommitmentTree:        ${deployedContracts.commitmentTree}`);
    console.log(`  GhostERC20:            ${deployedContracts.ghostToken}`);

    console.log("\n📋 UI Environment Variables:");
    console.log(`VITE_GHOST_TOKEN_ADDRESS=${deployedContracts.ghostToken}`);
    console.log(`VITE_COMMITMENT_TREE_ADDRESS=${deployedContracts.commitmentTree}`);
    console.log(`VITE_NULLIFIER_REGISTRY_ADDRESS=${deployedContracts.nullifierRegistry}`);
    console.log(`VITE_VERIFIER_ADDRESS=${deployedContracts.verifier}`);

  } catch (error) {
    console.error("\n❌ Deployment failed:", error);
    console.log("\nPartially deployed contracts:");
    console.log(JSON.stringify(deployedContracts, null, 2));
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
