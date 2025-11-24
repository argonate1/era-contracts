// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GhostERC20Harness} from "../test/foundry/ghost/helpers/GhostERC20Harness.sol";
import {CommitmentTree} from "../contracts/ghost/CommitmentTree.sol";
import {NullifierRegistry} from "../contracts/ghost/NullifierRegistry.sol";
import {GhostVerifier} from "../contracts/ghost/GhostVerifier.sol";

/**
 * @title DeployGhostRealZK
 * @notice Deploy Ghost Protocol with real ZK proof verification
 * @dev Run with: forge script script/DeployGhostRealZK.s.sol --rpc-url http://127.0.0.1:3050 --broadcast
 */
contract DeployGhostRealZK is Script {
    bytes32 public constant TEST_ASSET_ID = keccak256("TEST_ASSET");
    address public constant ORIGIN_TOKEN = address(0x1234);

    function run() external {
        uint256 deployerPrivateKey = 0x6c46624099e070e430736bd84989fa78b4f6403de8d161ecf27dcdb98f4cacb5;

        vm.startBroadcast(deployerPrivateKey);

        console2.log("Deploying Ghost Protocol with real ZK verification...");
        console2.log("");

        // 1. Deploy CommitmentTree
        console2.log("1. Deploying CommitmentTree...");
        CommitmentTree commitmentTree = new CommitmentTree();
        console2.log("   CommitmentTree deployed to:", address(commitmentTree));

        // 2. Deploy NullifierRegistry
        console2.log("2. Deploying NullifierRegistry...");
        NullifierRegistry nullifierRegistry = new NullifierRegistry();
        console2.log("   NullifierRegistry deployed to:", address(nullifierRegistry));

        // 3. Deploy GhostVerifier with REAL Groth16 verification
        console2.log("3. Deploying GhostVerifier (REAL ZK)...");
        GhostVerifier verifier = new GhostVerifier();
        console2.log("   GhostVerifier deployed to:", address(verifier));

        // 4. Deploy GhostERC20 test token
        console2.log("4. Deploying GhostERC20 Test Token...");
        GhostERC20Harness ghostToken = new GhostERC20Harness();
        ghostToken.initialize(
            TEST_ASSET_ID,
            ORIGIN_TOKEN,
            "Ghost Test Token",
            "gTEST",
            18,
            address(commitmentTree),
            address(nullifierRegistry),
            address(verifier)
        );
        console2.log("   GhostERC20 deployed to:", address(ghostToken));

        // 5. Authorize
        console2.log("5. Setting authorizations...");
        commitmentTree.authorizeInserter(address(ghostToken));
        nullifierRegistry.authorizeMarker(address(ghostToken));
        console2.log("   Authorizations set");

        // 6. Mint test tokens to deployer for testing
        console2.log("6. Minting test tokens...");
        address deployer = vm.addr(deployerPrivateKey);
        vm.stopBroadcast();

        // Can't call bridgeMint without being NTV, but the test harness sets deployer as NTV
        // Let's mint via the harness's bridge mint capability
        vm.startBroadcast(deployerPrivateKey);
        // The NTV is the deployer (msg.sender during initialize)
        ghostToken.bridgeMint(deployer, 10000 ether);
        console2.log("   Minted 10000 tokens to:", deployer);

        vm.stopBroadcast();

        // Summary
        console2.log("");
        console2.log("========================================");
        console2.log("Ghost Protocol Deployed!");
        console2.log("========================================");
        console2.log("CommitmentTree:    ", address(commitmentTree));
        console2.log("NullifierRegistry: ", address(nullifierRegistry));
        console2.log("GhostVerifier:     ", address(verifier));
        console2.log("GhostERC20:        ", address(ghostToken));
        console2.log("========================================");
        console2.log("");
        console2.log("USING REAL GROTH16 ZK VERIFICATION");
        console2.log("All redemptions require valid ZK proofs!");
    }
}
