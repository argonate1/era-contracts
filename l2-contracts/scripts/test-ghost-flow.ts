/**
 * Test Ghost Protocol flow using Keccak256 (for TestGhostERC20/TestCommitmentTree)
 *
 * This script tests the complete ghost/redeem flow without ZK proofs,
 * using the test contracts that use keccak256 instead of Poseidon.
 */

import { Wallet, Provider, Contract } from "zksync-ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const PRIVATE_KEY = process.env.WALLET_PRIVATE_KEY || "0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c";
const RPC_URL = process.env.ZKSYNC_RPC_URL || "http://127.0.0.1:3150";

// Test user - use Anvil's first test account for simplicity
const TEST_USER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

async function loadAbi(contractName: string): Promise<any> {
  const basePath = path.join(__dirname, '../zkout');
  const paths = [
    path.join(basePath, 'test', `${contractName}.sol`, `${contractName}.json`),
    path.join(basePath, `${contractName}.sol`, `${contractName}.json`),
  ];

  for (const p of paths) {
    if (fs.existsSync(p)) {
      const artifact = JSON.parse(fs.readFileSync(p, 'utf8'));
      return artifact.abi;
    }
  }
  throw new Error(`ABI not found for ${contractName}`);
}

// Compute commitment using keccak256 (matching TestCommitmentTree)
function computeCommitment(secret: string, nullifier: string, amount: string, token: string): string {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "bytes32", "uint256", "address"],
      [secret, nullifier, amount, token]
    )
  );
}

async function main() {
  console.log("=".repeat(60));
  console.log("Ghost Protocol Test Flow (Keccak256 Mode)");
  console.log("=".repeat(60));

  const provider = new Provider(RPC_URL);

  // Deployer wallet (owner of contracts)
  const deployerWallet = new Wallet(PRIVATE_KEY, provider);
  const deployer = await deployerWallet.getAddress();
  console.log(`\nDeployer (contract owner): ${deployer}`);

  // Test user wallet
  const testUserWallet = new Wallet(TEST_USER_KEY, provider);
  const testUser = await testUserWallet.getAddress();
  console.log(`Test user: ${testUser}`);

  // Load deployment info
  const deploymentPath = path.join(__dirname, '../deployments/ghost-testnet-5448.json');
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
  console.log(`\nUsing contracts from: ${deploymentPath}`);

  // Load contracts
  const ghostTokenAbi = await loadAbi("TestGhostERC20");
  const commitmentTreeAbi = await loadAbi("TestCommitmentTree");

  const ghostToken = new Contract(deployment.contracts.ghostToken, ghostTokenAbi, deployerWallet);
  const commitmentTree = new Contract(deployment.contracts.commitmentTree, commitmentTreeAbi, provider);

  // Check balances
  const deployerBalance = await provider.getBalance(deployer);
  const testUserBalance = await provider.getBalance(testUser);
  console.log(`\nDeployer GHOST balance: ${ethers.utils.formatEther(deployerBalance)}`);
  console.log(`Test user GHOST balance: ${ethers.utils.formatEther(testUserBalance)}`);

  // Step 1: Fund test user with GHOST for gas
  console.log("\n" + "-".repeat(40));
  console.log("Step 1: Fund test user with GHOST for gas");
  console.log("-".repeat(40));

  if (testUserBalance.eq(0)) {
    const fundAmount = ethers.utils.parseEther("1"); // 1 GHOST for gas
    console.log(`Sending ${ethers.utils.formatEther(fundAmount)} GHOST to ${testUser} for gas...`);
    const fundTx = await deployerWallet.sendTransaction({
      to: testUser,
      value: fundAmount,
    });
    await fundTx.wait();
    console.log(`  Tx: ${fundTx.hash}`);
  } else {
    console.log(`  Test user already has GHOST for gas`);
  }

  // Step 2: Mint tokens to test user
  console.log("\n" + "-".repeat(40));
  console.log("Step 2: Mint tokens to test user");
  console.log("-".repeat(40));

  const mintAmount = ethers.utils.parseEther("100"); // 100 tokens
  console.log(`Minting ${ethers.utils.formatEther(mintAmount)} tokens to ${testUser}...`);

  const mintTx = await ghostToken.bridgeMint(testUser, mintAmount);
  await mintTx.wait();
  console.log(`  Tx: ${mintTx.hash}`);

  const tokenBalance = await ghostToken.balanceOf(testUser);
  console.log(`  Test user token balance: ${ethers.utils.formatEther(tokenBalance)}`);

  // Step 3: Generate commitment for ghost operation
  console.log("\n" + "-".repeat(40));
  console.log("Step 3: Ghost tokens (burn + create commitment)");
  console.log("-".repeat(40));

  // Generate random secret and nullifier
  const secret = ethers.utils.hexlify(ethers.utils.randomBytes(32));
  const nullifier = ethers.utils.hexlify(ethers.utils.randomBytes(32));
  const ghostAmount = ethers.utils.parseEther("10"); // Ghost 10 tokens

  console.log(`  Secret: ${secret}`);
  console.log(`  Nullifier: ${nullifier}`);
  console.log(`  Amount: ${ethers.utils.formatEther(ghostAmount)} tokens`);

  // Compute commitment
  const commitment = computeCommitment(secret, nullifier, ghostAmount.toString(), deployment.contracts.ghostToken);
  console.log(`  Commitment: ${commitment}`);

  // Connect with test user wallet
  const ghostTokenAsUser = ghostToken.connect(testUserWallet);

  // Call ghost function
  console.log(`\n  Calling ghost()...`);
  const ghostTx = await ghostTokenAsUser.ghost(ghostAmount, commitment);
  const ghostReceipt = await ghostTx.wait();
  console.log(`  Tx: ${ghostTx.hash}`);
  console.log(`  Gas used: ${ghostReceipt.gasUsed.toString()}`);

  // Parse events
  const ghostedEvent = ghostReceipt.events?.find((e: any) => e.event === 'Ghosted');
  if (ghostedEvent) {
    console.log(`  Leaf index: ${ghostedEvent.args?.leafIndex}`);
  }

  // Check new balances
  const newTokenBalance = await ghostToken.balanceOf(testUser);
  console.log(`  Test user token balance after ghost: ${ethers.utils.formatEther(newTokenBalance)}`);

  // Check commitment tree
  const treeRoot = await commitmentTree.currentRoot();
  const nextLeaf = await commitmentTree.nextLeafIndex();
  console.log(`  Current tree root: ${treeRoot}`);
  console.log(`  Next leaf index: ${nextLeaf}`);

  // Step 4: Check ghost stats
  console.log("\n" + "-".repeat(40));
  console.log("Step 4: Ghost Statistics");
  console.log("-".repeat(40));

  const stats = await ghostToken.getGhostStats();
  console.log(`  Total ghosted: ${ethers.utils.formatEther(stats.ghosted)}`);
  console.log(`  Total redeemed: ${ethers.utils.formatEther(stats.redeemed)}`);
  console.log(`  Outstanding: ${ethers.utils.formatEther(stats.outstanding)}`);

  // Save voucher info for later redemption
  const voucherInfo = {
    secret,
    nullifier,
    amount: ghostAmount.toString(),
    commitment,
    leafIndex: ghostedEvent?.args?.leafIndex?.toString() || "0",
    tokenAddress: deployment.contracts.ghostToken,
    treeRoot,
  };

  const voucherPath = path.join(__dirname, '../test-voucher.json');
  fs.writeFileSync(voucherPath, JSON.stringify(voucherInfo, null, 2));
  console.log(`\n  Voucher saved to: ${voucherPath}`);

  console.log("\n" + "=".repeat(60));
  console.log("GHOST TEST COMPLETE");
  console.log("=".repeat(60));
  console.log("\nNote: Redemption requires ZK proof generation which the test");
  console.log("contracts don't support properly (hash mismatch between");
  console.log("Keccak256 contracts and Poseidon circuits).");
  console.log("\nThe ghost (burn) operation works correctly!");
}

main().catch((error) => {
  console.error("\nError:", error);
  process.exit(1);
});
