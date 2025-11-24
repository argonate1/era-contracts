/**
 * Ghost Protocol Deployment Script
 *
 * Deploys all Ghost protocol infrastructure contracts:
 * 1. CommitmentTree - Shared Merkle tree for all ghost tokens
 * 2. NullifierRegistry - Shared nullifier tracking
 * 3. GhostVerifier - ZK proof verifier (real Groth16 verification)
 * 4. GhostERC20 beacon - Upgradeable ghost token implementation
 * 5. GhostNativeTokenVault - Bridge integration for auto ghost tokens
 *
 * Usage:
 *   npx hardhat run scripts/deploy-ghost.ts --network <network>
 */

import { ethers, upgrades } from 'hardhat';
import { Contract, Wallet } from 'ethers';

// Constants from GhostConstants.sol
const GHOST_COMMITMENT_TREE = '0x0000000000000000000000000000000000010011';
const GHOST_NULLIFIER_REGISTRY = '0x0000000000000000000000000000000000010012';
const GHOST_VERIFIER = '0x0000000000000000000000000000000000010013';
const GHOST_ERC20_BEACON = '0x0000000000000000000000000000000000010014';
const GHOST_NATIVE_TOKEN_VAULT = '0x0000000000000000000000000000000000010010';

interface DeployedContracts {
    commitmentTree: string;
    nullifierRegistry: string;
    verifier: string;
    ghostERC20Beacon: string;
    ghostNativeTokenVault: string;
}

async function main(): Promise<DeployedContracts> {
    const [deployer] = await ethers.getSigners();
    console.log('Deploying Ghost Protocol with account:', deployer.address);
    console.log('Account balance:', ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

    // =========================================================================
    // 1. Deploy CommitmentTree
    // =========================================================================
    console.log('\n1. Deploying CommitmentTree...');
    const CommitmentTree = await ethers.getContractFactory('CommitmentTree');
    const commitmentTree = await CommitmentTree.deploy();
    await commitmentTree.waitForDeployment();
    const commitmentTreeAddress = await commitmentTree.getAddress();
    console.log('   CommitmentTree deployed to:', commitmentTreeAddress);

    // =========================================================================
    // 2. Deploy NullifierRegistry
    // =========================================================================
    console.log('\n2. Deploying NullifierRegistry...');
    const NullifierRegistry = await ethers.getContractFactory('NullifierRegistry');
    const nullifierRegistry = await NullifierRegistry.deploy();
    await nullifierRegistry.waitForDeployment();
    const nullifierRegistryAddress = await nullifierRegistry.getAddress();
    console.log('   NullifierRegistry deployed to:', nullifierRegistryAddress);

    // =========================================================================
    // 3. Deploy GhostVerifier (with real Groth16 verification)
    // =========================================================================
    console.log('\n3. Deploying GhostVerifier...');
    const GhostVerifier = await ethers.getContractFactory('GhostVerifier');
    const verifier = await GhostVerifier.deploy();
    await verifier.waitForDeployment();
    const verifierAddress = await verifier.getAddress();
    console.log('   GhostVerifier deployed to:', verifierAddress);
    console.log('   Using real Groth16 ZK proof verification');

    // =========================================================================
    // 4. Deploy GhostERC20 Implementation and Beacon
    // =========================================================================
    console.log('\n4. Deploying GhostERC20 Beacon...');
    const GhostERC20 = await ethers.getContractFactory('GhostERC20');
    const ghostERC20Implementation = await GhostERC20.deploy();
    await ghostERC20Implementation.waitForDeployment();
    const ghostERC20ImplAddress = await ghostERC20Implementation.getAddress();
    console.log('   GhostERC20 implementation deployed to:', ghostERC20ImplAddress);

    // Deploy UpgradeableBeacon
    const UpgradeableBeacon = await ethers.getContractFactory('@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon');
    const beacon = await UpgradeableBeacon.deploy(ghostERC20ImplAddress, deployer.address);
    await beacon.waitForDeployment();
    const beaconAddress = await beacon.getAddress();
    console.log('   UpgradeableBeacon deployed to:', beaconAddress);

    // =========================================================================
    // 5. Deploy GhostNativeTokenVault
    // =========================================================================
    console.log('\n5. Deploying GhostNativeTokenVault...');
    const GhostNativeTokenVault = await ethers.getContractFactory('GhostNativeTokenVault');
    const ghostNTV = await GhostNativeTokenVault.deploy();
    await ghostNTV.waitForDeployment();
    const ghostNTVAddress = await ghostNTV.getAddress();
    console.log('   GhostNativeTokenVault deployed to:', ghostNTVAddress);

    // =========================================================================
    // 6. Initialize GhostNativeTokenVault
    // =========================================================================
    console.log('\n6. Initializing GhostNativeTokenVault...');

    // Get L2AssetRouter address (this varies by deployment)
    // For local development, you may need to set this manually
    const L2_ASSET_ROUTER = process.env.L2_ASSET_ROUTER || '0x0000000000000000000000000000000000010003';

    const initTx = await ghostNTV.initialize(
        (await ethers.provider.getNetwork()).chainId,
        deployer.address, // owner
        commitmentTreeAddress,
        nullifierRegistryAddress,
        verifierAddress,
        beaconAddress,
        L2_ASSET_ROUTER
    );
    await initTx.wait();
    console.log('   GhostNativeTokenVault initialized');

    // =========================================================================
    // 7. Authorize contracts
    // =========================================================================
    console.log('\n7. Setting up authorizations...');

    // Authorize GhostNTV to insert into CommitmentTree
    const authTreeTx = await commitmentTree.authorizeInserter(ghostNTVAddress);
    await authTreeTx.wait();
    console.log('   Authorized GhostNTV to insert commitments');

    // Authorize GhostNTV to mark nullifiers
    const authNullTx = await nullifierRegistry.authorizeMarker(ghostNTVAddress);
    await authNullTx.wait();
    console.log('   Authorized GhostNTV to mark nullifiers');

    // =========================================================================
    // Summary
    // =========================================================================
    console.log('\n========================================');
    console.log('Ghost Protocol Deployment Complete!');
    console.log('========================================');
    console.log('CommitmentTree:       ', commitmentTreeAddress);
    console.log('NullifierRegistry:    ', nullifierRegistryAddress);
    console.log('GhostVerifier:        ', verifierAddress);
    console.log('GhostERC20 Beacon:    ', beaconAddress);
    console.log('GhostNativeTokenVault:', ghostNTVAddress);
    console.log('========================================');
    console.log('\n✅ Using real Groth16 ZK proof verification');
    console.log('   All redemptions require valid ZK proofs');

    // Save deployment addresses
    const deployment: DeployedContracts = {
        commitmentTree: commitmentTreeAddress,
        nullifierRegistry: nullifierRegistryAddress,
        verifier: verifierAddress,
        ghostERC20Beacon: beaconAddress,
        ghostNativeTokenVault: ghostNTVAddress,
    };

    const fs = require('fs');
    const deploymentPath = `deployments/ghost-${(await ethers.provider.getNetwork()).chainId}.json`;
    fs.mkdirSync('deployments', { recursive: true });
    fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
    console.log(`\nDeployment saved to: ${deploymentPath}`);

    return deployment;
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
