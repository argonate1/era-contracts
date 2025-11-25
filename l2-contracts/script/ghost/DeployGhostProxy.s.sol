// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../../contracts/ghost/GhostERC20.sol";
import "../../contracts/ghost/CommitmentTree.sol";
import "../../contracts/ghost/NullifierRegistry.sol";
import "../../contracts/ghost/GhostVerifier.sol";
import "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DeployGhostProxy
/// @notice Deploys just the proxy using existing deployed contracts
contract DeployGhostProxy is Script {
    // Pre-deployed contract addresses from first deployment
    address constant COMMITMENT_TREE = 0x456e224ADe45E4C4809F89D03C92Df65165f86CA;
    address constant NULLIFIER_REGISTRY = 0xbFaF8231ED01e2631AfFE7F5e3c6d85006B8b33F;
    address constant GHOST_VERIFIER = 0xB4D01F758b7725a7190F5db700Fc081c44Ec626a;
    address constant GHOST_IMPL = 0x40BB523D068279b998205A69a184f1146376b89f;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c)
        );

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Set root submitter on CommitmentTree
        CommitmentTree(COMMITMENT_TREE).setRootSubmitter(deployer);
        console.log("Root submitter set to:", deployer);

        // Deploy proxy
        address mockOriginToken = address(0x1234567890123456789012345678901234567890);
        bytes32 assetId = keccak256(abi.encodePacked("GHOST_TEST_TOKEN"));

        bytes memory initData = abi.encodeWithSelector(
            GhostERC20.initialize.selector,
            assetId,
            mockOriginToken,
            "Test Token",
            "TEST",
            uint8(18),
            COMMITMENT_TREE,
            NULLIFIER_REGISTRY,
            GHOST_VERIFIER
        );

        ERC1967Proxy proxy = new ERC1967Proxy(GHOST_IMPL, initData);
        GhostERC20 ghostToken = GhostERC20(address(proxy));
        console.log("GhostERC20 proxy deployed at:", address(ghostToken));

        // Grant permissions
        NullifierRegistry(NULLIFIER_REGISTRY).authorizeMarker(address(ghostToken));
        console.log("Granted NullifierRegistry permissions to GhostERC20");

        CommitmentTree(COMMITMENT_TREE).authorizeInserter(address(ghostToken));
        console.log("Granted CommitmentTree permissions to GhostERC20");

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("VITE_GHOST_TOKEN_ADDRESS=%s", address(ghostToken));
        console.log("VITE_COMMITMENT_TREE_ADDRESS=%s", COMMITMENT_TREE);
        console.log("VITE_NULLIFIER_REGISTRY_ADDRESS=%s", NULLIFIER_REGISTRY);
        console.log("VITE_VERIFIER_PROXY_ADDRESS=%s", GHOST_VERIFIER);

        vm.stopBroadcast();
    }
}
