/**
 * Deploy Ghost Protocol TEST contracts (Keccak-based) to zkSync testnet
 *
 * This script deploys test versions of Ghost Protocol contracts that use
 * keccak256 instead of Poseidon for hashing. This is for testing the
 * protocol flow without requiring zkSync-compatible Poseidon assembly.
 *
 * WARNING: These contracts DO NOT match the ZK circuits and should only
 * be used for integration testing.
 */

import { Wallet, Provider, ContractFactory, Contract } from "zksync-ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const PRIVATE_KEY = process.env.WALLET_PRIVATE_KEY || "0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c";
const RPC_URL = process.env.ZKSYNC_RPC_URL || "http://127.0.0.1:3150";

// Already deployed contracts (from previous production run on chain 5448)
const REDEEM_VERIFIER_ADDRESS = "0x75FC40a8569a11070f831CFaFe2e66Ff4120767d";
const PARTIAL_REDEEM_VERIFIER_ADDRESS = "0xc925014acF9a9A80aD7740D3dE5B88cCaBb86981";
const VERIFIER_ADDRESS = "0x238b0e95fD20A544D0f085b2f103528B74529Ec1";
const NULLIFIER_REGISTRY_ADDRESS = "0x86D815CEBda3Ee77C3325A9BDd96F171c27613BE";

async function loadArtifact(contractName: string, subdir?: string): Promise<{abi: any, bytecode: string}> {
  // Try various path patterns
  const basePath = path.join(__dirname, '../zkout');
  const paths = [
    // zkout/test/ContractName.sol/ContractName.json
    path.join(basePath, subdir || '', `${contractName}.sol`, `${contractName}.json`),
    // zkout/ContractName.sol/ContractName.json
    path.join(basePath, `${contractName}.sol`, `${contractName}.json`),
  ];

  let artifactPath: string | null = null;
  for (const p of paths) {
    console.log(`  Checking: ${p}`);
    if (fs.existsSync(p)) {
      artifactPath = p;
      break;
    }
  }

  if (!artifactPath) {
    throw new Error(`Artifact not found for ${contractName}. Tried: ${paths.join(', ')}. Run 'forge build --zksync' first.`);
  }
  console.log(`  Found artifact: ${artifactPath}`);

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

  // Add manual gas limit for contracts that might need it
  if (gasLimit) {
    (deployTx as any).gasLimit = gasLimit;
    console.log(`  Using manual gas limit: ${gasLimit}`);
  }

  const sentTx = await wallet.sendTransaction(deployTx);
  console.log(`  Transaction hash: ${sentTx.hash}`);

  const receipt = await sentTx.wait();
  const address = receipt.contractAddress!;
  console.log(`  Deployed to: ${address}`);

  // Verify deployment
  const code = await wallet.provider!.getCode(address);
  console.log(`  Contract code length: ${code.length}`);
  if (code.length <= 2) {
    throw new Error(`Contract deployment failed - no code at ${address}`);
  }

  return address;
}

async function main() {
  console.log("=".repeat(60));
  console.log("Ghost Protocol - TESTNET Deployment (Keccak-based)");
  console.log("=".repeat(60));
  console.log("\n⚠️  WARNING: This deploys TEST contracts that use keccak256");
  console.log("   instead of Poseidon. NOT FOR PRODUCTION USE.\n");

  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const deployer = await wallet.getAddress();
  console.log(`Deployer: ${deployer}`);

  const balance = await provider.getBalance(deployer);
  console.log(`Balance: ${ethers.utils.formatEther(balance)} GHOST`);

  const network = await provider.getNetwork();
  console.log(`Chain ID: ${network.chainId}`);

  console.log("\nUsing already deployed contracts:");
  console.log(`  GhostVerifierProxy: ${VERIFIER_ADDRESS}`);
  console.log(`  NullifierRegistry: ${NULLIFIER_REGISTRY_ADDRESS}`);

  const deployedContracts: Record<string, string> = {
    redeemVerifier: REDEEM_VERIFIER_ADDRESS,
    partialRedeemVerifier: PARTIAL_REDEEM_VERIFIER_ADDRESS,
    verifier: VERIFIER_ADDRESS,
    nullifierRegistry: NULLIFIER_REGISTRY_ADDRESS,
  };

  try {
    // Deploy TestCommitmentTree (Keccak-based, much cheaper)
    console.log("\n" + "-".repeat(40));
    console.log("Deploying TestCommitmentTree (Keccak-based)");
    console.log("-".repeat(40));
    deployedContracts.commitmentTree = await deployContract(
      wallet,
      "TestCommitmentTree",
      [],
      BigInt(15000000),  // 15M gas should be plenty for keccak
      "test"
    );

    // Deploy GhostERC20 (upgradeable pattern - deploy then initialize)
    console.log("\n" + "-".repeat(40));
    console.log("Deploying GhostERC20");
    console.log("-".repeat(40));
    deployedContracts.ghostToken = await deployContract(
      wallet,
      "GhostERC20",
      [],
      BigInt(50000000)  // 50M gas for larger contract
    );

    // Initialize the GhostERC20 contract
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

    const commitmentTreeArtifact = await loadArtifact("TestCommitmentTree", "test");
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
      testMode: true,
      hashFunction: "Keccak256 (TEST ONLY)",
      warning: "These contracts use keccak256 instead of Poseidon and DO NOT match ZK circuits"
    };

    const outputPath = path.join(__dirname, `../deployments/ghost-testnet-${network.chainId}.json`);
    const outputDir = path.dirname(outputPath);
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true });
    }
    fs.writeFileSync(outputPath, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n" + "=".repeat(60));
    console.log("DEPLOYMENT COMPLETE (Testnet - Keccak)");
    console.log("=".repeat(60));
    console.log("\n⚠️  REMINDER: These are TEST contracts using keccak256!");
    console.log("   They will NOT work with ZK proofs.\n");
    console.log("📋 UI Environment Variables:");
    console.log(`VITE_GHOST_TOKEN_ADDRESS=${deployedContracts.ghostToken}`);
    console.log(`VITE_COMMITMENT_TREE_ADDRESS=${deployedContracts.commitmentTree}`);
    console.log(`VITE_NULLIFIER_REGISTRY_ADDRESS=${deployedContracts.nullifierRegistry}`);
    console.log(`VITE_VERIFIER_ADDRESS=${deployedContracts.verifier}`);
    console.log(`\nDeployment saved to: ${outputPath}`);

  } catch (error) {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
