import { Wallet, Provider, Contract, utils } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { HardhatRuntimeEnvironment } from "hardhat/types";

// Default test account private key (has funds on local zkstack)
const RICH_WALLET_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

export default async function (hre: HardhatRuntimeEnvironment) {
  console.log("Deploying Ghost Protocol contracts...");

  // Initialize the provider and wallet
  const provider = new Provider(hre.network.config.url);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY || RICH_WALLET_PK, provider);
  const deployer = new Deployer(hre, wallet);

  console.log(`Deployer address: ${wallet.address}`);
  const balance = await provider.getBalance(wallet.address);
  console.log(`Deployer balance: ${balance.toString()} wei`);

  // 1. Deploy CommitmentTree
  console.log("\n1. Deploying CommitmentTree...");
  const commitmentTreeArtifact = await deployer.loadArtifact("CommitmentTree");
  const commitmentTree = await deployer.deploy(commitmentTreeArtifact);
  await commitmentTree.waitForDeployment();
  const commitmentTreeAddress = await commitmentTree.getAddress();
  console.log(`CommitmentTree deployed at: ${commitmentTreeAddress}`);

  // 2. Deploy NullifierRegistry
  console.log("\n2. Deploying NullifierRegistry...");
  const nullifierRegistryArtifact = await deployer.loadArtifact("NullifierRegistry");
  const nullifierRegistry = await deployer.deploy(nullifierRegistryArtifact);
  await nullifierRegistry.waitForDeployment();
  const nullifierRegistryAddress = await nullifierRegistry.getAddress();
  console.log(`NullifierRegistry deployed at: ${nullifierRegistryAddress}`);

  // 3. Deploy GhostVerifier in test mode
  console.log("\n3. Deploying GhostVerifier (test mode)...");
  const ghostVerifierArtifact = await deployer.loadArtifact("GhostVerifier");
  const ghostVerifier = await deployer.deploy(ghostVerifierArtifact, [true]); // testMode = true
  await ghostVerifier.waitForDeployment();
  const ghostVerifierAddress = await ghostVerifier.getAddress();
  console.log(`GhostVerifier deployed at: ${ghostVerifierAddress}`);

  // 4. Deploy GhostERC20 implementation
  console.log("\n4. Deploying GhostERC20 implementation...");
  const ghostERC20Artifact = await deployer.loadArtifact("GhostERC20");
  const ghostImpl = await deployer.deploy(ghostERC20Artifact);
  await ghostImpl.waitForDeployment();
  const ghostImplAddress = await ghostImpl.getAddress();
  console.log(`GhostERC20 implementation deployed at: ${ghostImplAddress}`);

  // 5. Deploy ERC1967Proxy and initialize
  console.log("\n5. Deploying ERC1967Proxy and initializing GhostERC20...");
  const mockOriginToken = "0x1234567890123456789012345678901234567890";
  // Use hardcoded assetId for testing
  const assetId = "0x0000000000000000000000000000000000000000000000000000000000000001";

  const initData = ghostImpl.interface.encodeFunctionData("initialize", [
    assetId,
    mockOriginToken,
    "Test Token",
    "TEST",
    18,
    commitmentTreeAddress,
    nullifierRegistryAddress,
    ghostVerifierAddress,
  ]);

  const proxyArtifact = await deployer.loadArtifact("@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy");
  const proxy = await deployer.deploy(proxyArtifact, [ghostImplAddress, initData]);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  console.log(`GhostERC20 proxy deployed at: ${proxyAddress}`);

  // 6. Grant permissions
  console.log("\n6. Granting NullifierRegistry permissions to GhostERC20...");
  const nullifierRegistryContract = new Contract(
    nullifierRegistryAddress,
    nullifierRegistryArtifact.abi,
    wallet
  );
  const authTx = await nullifierRegistryContract.authorizeMarker(proxyAddress);
  await authTx.wait();
  console.log("Granted NullifierRegistry permissions to GhostERC20");

  // Summary
  console.log("\n=== Deployment Complete ===");
  console.log("Contract Addresses:");
  console.log(`  CommitmentTree: ${commitmentTreeAddress}`);
  console.log(`  NullifierRegistry: ${nullifierRegistryAddress}`);
  console.log(`  GhostVerifier: ${ghostVerifierAddress}`);
  console.log(`  GhostERC20 (impl): ${ghostImplAddress}`);
  console.log(`  GhostERC20 (proxy): ${proxyAddress}`);
  console.log("\nAdd this to your .env file:");
  console.log(`VITE_GHOST_TOKEN_ADDRESS=${proxyAddress}`);

  return {
    commitmentTree: commitmentTreeAddress,
    nullifierRegistry: nullifierRegistryAddress,
    ghostVerifier: ghostVerifierAddress,
    ghostImpl: ghostImplAddress,
    ghostProxy: proxyAddress,
  };
}
