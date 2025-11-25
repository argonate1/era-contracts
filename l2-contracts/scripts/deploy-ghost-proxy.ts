/**
 * Deploy ERC1967Proxy for GhostERC20
 *
 * This deploys a proxy pointing to the GhostERC20 implementation and initializes it.
 */

import { Wallet, Provider, ContractFactory, Contract, utils } from "zksync-ethers";
import { ethers, utils as ethersUtils } from "ethers";
import * as fs from "fs";
import * as path from "path";

const PRIVATE_KEY = process.env.WALLET_PRIVATE_KEY || "0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c";
const RPC_URL = process.env.ZKSYNC_RPC_URL || "http://127.0.0.1:3150";

// Contract addresses from previous deployment
const ADDRESSES = {
  ghostERC20Impl: "0xbFaF8231ED01e2631AfFE7F5e3c6d85006B8b33F",
  commitmentTree: "0x456e224ADe45E4C4809F89D03C92Df65165f86CA",
  nullifierRegistry: "0x86D815CEBda3Ee77C3325A9BDd96F171c27613BE",
  ghostVerifierProxy: "0x238b0e95fD20A544D0f085b2f103528B74529Ec1"
};

// ERC1967Proxy ABI (minimal for deployment)
const ERC1967_PROXY_ABI = [
  "constructor(address _logic, bytes memory _data)"
];

// GhostERC20 initialize function ABI for encoding
const GHOST_ERC20_INIT_ABI = [
  "function initialize(bytes32 _assetId, address _originToken, string memory _name, string memory _symbol, uint8 _tokenDecimals, address _commitmentTree, address _nullifierRegistry, address _verifier)"
];

async function loadArtifact(contractPath: string): Promise<{abi: any, bytecode: string}> {
  // Try zkout first, then node_modules
  const zkoutPath = path.join(__dirname, `../zkout/${contractPath}`);
  const nodeModulesPath = path.join(__dirname, `../node_modules/@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol/ERC1967Proxy.json`);

  let artifactPath = zkoutPath;
  if (!fs.existsSync(zkoutPath)) {
    // Try to load from zkout with different structure
    const parts = contractPath.split('/');
    const fileName = parts[parts.length - 1].replace('.json', '');
    const altPath = path.join(__dirname, `../zkout/${fileName}.sol/${fileName}.json`);
    if (fs.existsSync(altPath)) {
      artifactPath = altPath;
    } else {
      throw new Error(`Artifact not found at ${zkoutPath} or ${altPath}. Compile the contract first.`);
    }
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  let bytecode = artifact.bytecode?.object || artifact.bytecode;

  if (!bytecode) {
    throw new Error(`No bytecode found in artifact: ${artifactPath}`);
  }

  // Ensure bytecode is padded to 32-byte boundary for ZKsync
  const cleanBytecode = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode;
  const bytesLength = cleanBytecode.length / 2;
  const remainder = bytesLength % 32;
  if (remainder !== 0) {
    const paddingBytes = 32 - remainder;
    bytecode = cleanBytecode + '00'.repeat(paddingBytes);
    console.log(`  Padded bytecode by ${paddingBytes} bytes for ZKsync compatibility`);
  } else {
    bytecode = cleanBytecode;
  }

  return {
    abi: artifact.abi,
    bytecode: '0x' + bytecode
  };
}

async function main() {
  console.log("=".repeat(60));
  console.log("Deploying ERC1967Proxy for GhostERC20");
  console.log("=".repeat(60));
  console.log(`\nRPC URL: ${RPC_URL}`);

  // Setup provider and wallet
  const provider = new Provider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const deployer = await wallet.getAddress();

  console.log(`Deployer: ${deployer}`);
  const balance = await provider.getBalance(deployer);
  console.log(`Balance: ${ethersUtils.formatEther(balance)} ETH`);

  // Encode the initialize call
  const iface = new ethersUtils.Interface(GHOST_ERC20_INIT_ABI);

  // Parameters for initialize:
  // - assetId: simple placeholder
  // - originToken: placeholder L1 address
  // - name: "Test Token"
  // - symbol: "TEST"
  // - decimals: 18
  // - commitmentTree: our deployed address
  // - nullifierRegistry: our deployed address
  // - verifier: our deployed GhostVerifierProxy

  const initData = iface.encodeFunctionData("initialize", [
    ethersUtils.hexZeroPad("0x01", 32),  // assetId
    "0x0000000000000000000000000000000000000001",  // originToken (placeholder)
    "Test Token",
    "TEST",
    18,
    ADDRESSES.commitmentTree,
    ADDRESSES.nullifierRegistry,
    ADDRESSES.ghostVerifierProxy
  ]);

  console.log(`\nInit data encoded: ${initData.slice(0, 66)}...`);

  // Try to load ERC1967Proxy artifact
  let artifact;
  try {
    artifact = await loadArtifact("ERC1967Proxy.sol/ERC1967Proxy.json");
  } catch (e) {
    console.log("\nERC1967Proxy not compiled. Compiling now...");
    // We need to compile it first
    const { execSync } = require('child_process');
    execSync('forge build --zksync node_modules/@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol', {
      cwd: path.join(__dirname, '..'),
      stdio: 'inherit'
    });
    artifact = await loadArtifact("ERC1967Proxy.sol/ERC1967Proxy.json");
  }

  console.log(`\nDeploying ERC1967Proxy...`);
  console.log(`  Implementation: ${ADDRESSES.ghostERC20Impl}`);

  const factory = new ContractFactory(
    artifact.abi,
    artifact.bytecode,
    wallet,
    "create"
  );

  // Deploy with constructor args: (implementation, initData)
  const deployTx = await factory.getDeployTransaction(
    ADDRESSES.ghostERC20Impl,
    initData
  );

  const sentTx = await wallet.sendTransaction(deployTx);
  console.log(`  Transaction hash: ${sentTx.hash}`);

  const receipt = await sentTx.wait();
  const proxyAddress = receipt.contractAddress!;
  console.log(`  Proxy deployed to: ${proxyAddress}`);

  // Verify the proxy works by calling through to the implementation
  console.log(`\nVerifying proxy...`);

  const ghostERC20 = new Contract(
    proxyAddress,
    [
      "function name() view returns (string)",
      "function symbol() view returns (string)",
      "function decimals() view returns (uint8)",
      "function commitmentTree() view returns (address)",
      "function nullifierRegistry() view returns (address)",
      "function verifier() view returns (address)",
      "function isTestContract() pure returns (bool)",
      "function hashFunction() pure returns (string)"
    ],
    wallet
  );

  try {
    const name = await ghostERC20.name();
    const symbol = await ghostERC20.symbol();
    const decimals = await ghostERC20.decimals();
    const tree = await ghostERC20.commitmentTree();
    const registry = await ghostERC20.nullifierRegistry();
    const verifier = await ghostERC20.verifier();
    const isTest = await ghostERC20.isTestContract();
    const hashFn = await ghostERC20.hashFunction();

    console.log(`  Name: ${name}`);
    console.log(`  Symbol: ${symbol}`);
    console.log(`  Decimals: ${decimals}`);
    console.log(`  CommitmentTree: ${tree}`);
    console.log(`  NullifierRegistry: ${registry}`);
    console.log(`  Verifier: ${verifier}`);
    console.log(`  isTestContract: ${isTest}`);
    console.log(`  hashFunction: ${hashFn}`);
  } catch (e: any) {
    console.log(`  Warning: Could not verify proxy - ${e.message}`);
  }

  // Save deployment info
  const deploymentInfo = {
    network: "umbraline",
    chainId: 5448,
    timestamp: new Date().toISOString(),
    contracts: {
      RedeemVerifier: "0x75FC40a8569a11070f831CFaFe2e66Ff4120767d",
      PartialRedeemVerifier: "0xc925014acF9a9A80aD7740D3dE5B88cCaBb86981",
      GhostVerifierProxy: ADDRESSES.ghostVerifierProxy,
      NullifierRegistry: ADDRESSES.nullifierRegistry,
      PoseidonT3: "0x5F3a4d9C2e2f98B5a05F8014e04192Fd1C39D6A1",
      CommitmentTree: ADDRESSES.commitmentTree,
      GhostERC20_Implementation: ADDRESSES.ghostERC20Impl,
      GhostERC20_Proxy: proxyAddress
    },
    tokenConfig: {
      name: "Ghost Test Token",
      symbol: "gTEST",
      decimals: 18
    }
  };

  const deploymentsDir = path.join(__dirname, '../deployments');
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const deploymentPath = path.join(deploymentsDir, 'ghost-production-5448.json');
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\nDeployment info saved to: ${deploymentPath}`);

  // Print VITE environment variables for UI
  console.log(`\n${"=".repeat(60)}`);
  console.log("UI Environment Variables:");
  console.log(`${"=".repeat(60)}`);
  console.log(`VITE_GHOST_TOKEN_ADDRESS=${proxyAddress}`);
  console.log(`VITE_COMMITMENT_TREE_ADDRESS=${ADDRESSES.commitmentTree}`);
  console.log(`VITE_NULLIFIER_REGISTRY_ADDRESS=${ADDRESSES.nullifierRegistry}`);
  console.log(`VITE_VERIFIER_PROXY_ADDRESS=${ADDRESSES.ghostVerifierProxy}`);
  console.log(`VITE_POSEIDON_ADDRESS=0x5F3a4d9C2e2f98B5a05F8014e04192Fd1C39D6A1`);

  console.log(`\n${"=".repeat(60)}`);
  console.log("Deployment Complete!");
  console.log(`${"=".repeat(60)}`);
}

main().catch(console.error);
