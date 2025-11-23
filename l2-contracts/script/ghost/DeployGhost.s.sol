// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../../contracts/ghost/GhostERC20.sol";
import "../../contracts/ghost/CommitmentTree.sol";
import "../../contracts/ghost/NullifierRegistry.sol";
import "../../contracts/ghost/GhostVerifier.sol";
import "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployGhost
/// @notice Deploys the Ghost Protocol contracts for local development
/// @dev Run with: forge script script/ghost/DeployGhost.s.sol --rpc-url http://localhost:3050 --broadcast
contract DeployGhost is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0x3eb15da85647edd9a1159a4a13b9e7c56877c4eb33f614546d4db06a51868b1c) // Default dev key
        );

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CommitmentTree (uses Poseidon library internally)
        CommitmentTree commitmentTree = new CommitmentTree();
        console.log("CommitmentTree deployed at:", address(commitmentTree));

        // 2. Deploy NullifierRegistry
        NullifierRegistry nullifierRegistry = new NullifierRegistry();
        console.log("NullifierRegistry deployed at:", address(nullifierRegistry));

        // 3. Deploy GhostVerifier in test mode (accepts all proofs)
        GhostVerifier verifier = new GhostVerifier(true); // testMode = true
        console.log("GhostVerifier deployed at:", address(verifier));

        // 4. Deploy GhostERC20 implementation
        GhostERC20 ghostImpl = new GhostERC20();
        console.log("GhostERC20 implementation deployed at:", address(ghostImpl));

        // 5. Deploy proxy and initialize
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

        // 6. Grant permissions to the GhostERC20 token
        nullifierRegistry.authorizeMarker(address(ghostToken));
        console.log("Granted NullifierRegistry permissions to GhostERC20");

        // 7. Authorize GhostERC20 to insert commitments into the tree
        commitmentTree.authorizeInserter(address(ghostToken));
        console.log("Granted CommitmentTree permissions to GhostERC20");

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Add this to your .env file:");
        console.log("VITE_GHOST_TOKEN_ADDRESS=%s", address(ghostToken));

        vm.stopBroadcast();
    }
}
