import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { Wallet } from "zksync-ethers";
import { ethers } from "ethers";

const PRIVATE_KEY = "0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5";
const TEST_ASSET_ID = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("TEST_ASSET"));
const ORIGIN_TOKEN = "0x0000000000000000000000000000000000001234";

export default async function (hre: HardhatRuntimeEnvironment) {
  console.log("========================================");
  console.log("Ghost Protocol Deployment (ZKsync)");
  console.log("========================================\n");

  // Initialize wallet
  const wallet = new Wallet(PRIVATE_KEY);
  const deployer = new Deployer(hre, wallet);

  console.log("Deployer address:", wallet.address);

  // 1. Deploy CommitmentTree
  console.log("\n1. Deploying CommitmentTree...");
  const commitmentTreeArtifact = await deployer.loadArtifact("CommitmentTree");
  const commitmentTree = await deployer.deploy(commitmentTreeArtifact);
  const commitmentTreeAddress = await commitmentTree.getAddress();
  console.log("   CommitmentTree deployed to:", commitmentTreeAddress);

  // 2. Deploy NullifierRegistry
  console.log("\n2. Deploying NullifierRegistry...");
  const nullifierRegistryArtifact = await deployer.loadArtifact("NullifierRegistry");
  const nullifierRegistry = await deployer.deploy(nullifierRegistryArtifact);
  const nullifierRegistryAddress = await nullifierRegistry.getAddress();
  console.log("   NullifierRegistry deployed to:", nullifierRegistryAddress);

  // 3. Deploy GhostVerifier (real ZK)
  console.log("\n3. Deploying GhostVerifier (Real ZK)...");
  const verifierArtifact = await deployer.loadArtifact("GhostVerifier");
  const verifier = await deployer.deploy(verifierArtifact);
  const verifierAddress = await verifier.getAddress();
  console.log("   GhostVerifier deployed to:", verifierAddress);

  // 4. Deploy GhostERC20Harness
  console.log("\n4. Deploying GhostERC20Harness...");
  const ghostTokenArtifact = await deployer.loadArtifact("GhostERC20Harness");
  const ghostToken = await deployer.deploy(ghostTokenArtifact);
  const ghostTokenAddress = await ghostToken.getAddress();
  console.log("   GhostERC20Harness deployed to:", ghostTokenAddress);

  // 5. Initialize GhostERC20Harness
  console.log("\n5. Initializing GhostERC20Harness...");
  const initTx = await ghostToken.initialize(
    TEST_ASSET_ID,
    ORIGIN_TOKEN,
    "Ghost Test Token",
    "gTEST",
    18,
    commitmentTreeAddress,
    nullifierRegistryAddress,
    verifierAddress
  );
  await initTx.wait();
  console.log("   Initialized");

  // 6. Set authorizations
  console.log("\n6. Setting authorizations...");
  const authTreeTx = await commitmentTree.authorizeInserter(ghostTokenAddress);
  await authTreeTx.wait();
  console.log("   Authorized GhostToken to insert commitments");

  const authNullTx = await nullifierRegistry.authorizeMarker(ghostTokenAddress);
  await authNullTx.wait();
  console.log("   Authorized GhostToken to mark nullifiers");

  // 7. Mint test tokens
  console.log("\n7. Minting test tokens...");
  const mintTx = await ghostToken.bridgeMint(wallet.address, ethers.utils.parseEther("10000"));
  await mintTx.wait();
  console.log("   Minted 10000 tokens to:", wallet.address);

  // Summary
  console.log("\n========================================");
  console.log("Ghost Protocol Deployed!");
  console.log("========================================");
  console.log("CommitmentTree:    ", commitmentTreeAddress);
  console.log("NullifierRegistry: ", nullifierRegistryAddress);
  console.log("GhostVerifier:     ", verifierAddress);
  console.log("GhostERC20:        ", ghostTokenAddress);
  console.log("========================================");
  console.log("\nUSING REAL GROTH16 ZK VERIFICATION");
  console.log("All redemptions require valid ZK proofs!");

  // Update UI .env
  const fs = await import("fs");
  const path = await import("path");
  const uiEnvPath = path.join(__dirname, "..", "..", "..", "sdk", "ghost-ui", ".env");
  fs.writeFileSync(uiEnvPath, `VITE_GHOST_TOKEN_ADDRESS=${ghostTokenAddress}\n`);
  console.log(`\nUI .env updated with: ${ghostTokenAddress}`);
}
