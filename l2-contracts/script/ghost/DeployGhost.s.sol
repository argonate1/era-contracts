// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../../contracts/ghost/GhostERC20.sol";
import "../../contracts/ghost/CommitmentTree.sol";
import "../../contracts/ghost/NullifierRegistry.sol";
import "../../contracts/ghost/GhostVerifier.sol";
import "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployGhost
/// @notice Deploys the Ghost Protocol contracts for local development (off-chain tree architecture)
/// @dev Run with: forge script script/ghost/DeployGhost.s.sol --rpc-url http://localhost:3050 --broadcast
///
///      Architecture:
///      - CommitmentTree stores commitments and roots, but does NOT compute Merkle tree
///      - Merkle tree computation happens OFF-CHAIN using Poseidon (circomlibjs)
///      - Authorized relayer submits roots to CommitmentTree
///      - This avoids the 30KB bytecode limit of on-chain Poseidon
contract DeployGhost is Script {
    // Precomputed initial root for empty tree (Z20 - must match SDK)
    bytes32 constant INITIAL_ROOT = bytes32(0x0b4a6c626bd085f652fb17cad5b70c9db903266b5a3f456ea6373a3cf97f3453);

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0x3eb15da85647edd9a1159a4a13b9e7c56877c4eb33f614546d4db06a51868b1c) // Default dev key
        );

        // For local dev, use deployer as relayer
        address relayer = vm.addr(deployerPrivateKey);
        console.log("Deployer/Relayer address:", relayer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CommitmentTree with initial root (off-chain tree architecture)
        CommitmentTree commitmentTree = new CommitmentTree(INITIAL_ROOT);
        console.log("CommitmentTree deployed at:", address(commitmentTree));

        // 2. Set deployer as root submitter for local dev
        commitmentTree.setRootSubmitter(relayer);
        console.log("Root submitter set to:", relayer);

        // 3. Deploy NullifierRegistry
        NullifierRegistry nullifierRegistry = new NullifierRegistry();
        console.log("NullifierRegistry deployed at:", address(nullifierRegistry));

        // 4. Deploy GhostVerifier in test mode (accepts all proofs)
        GhostVerifier verifier = new GhostVerifier(true); // testMode = true
        console.log("GhostVerifier deployed at:", address(verifier));

        // 5. Deploy GhostERC20 implementation
        GhostERC20 ghostImpl = new GhostERC20();
        console.log("GhostERC20 implementation deployed at:", address(ghostImpl));

        // 6. Deploy proxy and initialize
        // Using a mock origin token address for local dev
        address mockOriginToken = address(0x1234567890123456789012345678901234567890);
        bytes32 assetId = keccak256(abi.encodePacked("GHOST_TEST_TOKEN"));

        bytes memory initData = abi.encodeWithSelector(
            GhostERC20.initialize.selector,
            assetId,
            mockOriginToken,
            "Test Token",
            "TEST",
            uint8(18),
            address(commitmentTree),
            address(nullifierRegistry),
            address(verifier)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(ghostImpl), initData);
        GhostERC20 ghostToken = GhostERC20(address(proxy));
        console.log("GhostERC20 proxy deployed at:", address(ghostToken));

        // 7. Grant permissions to the GhostERC20 token
        nullifierRegistry.authorizeMarker(address(ghostToken));
        console.log("Granted NullifierRegistry permissions to GhostERC20");

        // 8. Authorize GhostERC20 to insert commitments into the tree
        commitmentTree.authorizeInserter(address(ghostToken));
        console.log("Granted CommitmentTree permissions to GhostERC20");

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("");
        console.log("IMPORTANT: Off-Chain Tree Architecture");
        console.log("- Merkle tree computed OFF-CHAIN using Poseidon");
        console.log("- Relayer submits roots after each ghost operation");
        console.log("- Initial root:", vm.toString(INITIAL_ROOT));
        console.log("");
        console.log("Add this to your .env file:");
        console.log("VITE_GHOST_TOKEN_ADDRESS=%s", address(ghostToken));
        console.log("VITE_COMMITMENT_TREE_ADDRESS=%s", address(commitmentTree));
        console.log("VITE_RELAYER_ADDRESS=%s", relayer);

        vm.stopBroadcast();
    }
}
