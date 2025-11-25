// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../../contracts/ghost/test/TestGhostERC20.sol";
import "../../contracts/ghost/CommitmentTree.sol";
import "../../contracts/ghost/NullifierRegistry.sol";
import "../../contracts/ghost/GhostVerifier.sol";

/// @title DeployTestGhost
/// @notice Deploys TestGhostERC20 for local development with mint capability
contract DeployTestGhost is Script {
    // Pre-deployed contract addresses
    address constant COMMITMENT_TREE = 0x456e224ADe45E4C4809F89D03C92Df65165f86CA;
    address constant NULLIFIER_REGISTRY = 0xbFaF8231ED01e2631AfFE7F5e3c6d85006B8b33F;
    address constant GHOST_VERIFIER = 0xB4D01F758b7725a7190F5db700Fc081c44Ec626a;

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            uint256(0xb9740374221c300084dbf462fe6a6e355d0b51d23738a65ca8c1fdc7ff51785c)
        );

        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy TestGhostERC20
        TestGhostERC20 testToken = new TestGhostERC20();
        console.log("TestGhostERC20 deployed at:", address(testToken));

        // Initialize
        address mockOriginToken = address(0x1234567890123456789012345678901234567890);
        bytes32 assetId = keccak256(abi.encodePacked("GHOST_TEST_TOKEN_V2"));

        testToken.initialize(
            assetId,
            mockOriginToken,
            "Test Ghost Token",
            "tGHOST",
            18,
            COMMITMENT_TREE,
            NULLIFIER_REGISTRY,
            GHOST_VERIFIER
        );
        console.log("TestGhostERC20 initialized");

        // Grant permissions
        NullifierRegistry(NULLIFIER_REGISTRY).authorizeMarker(address(testToken));
        console.log("Granted NullifierRegistry permissions");

        CommitmentTree(COMMITMENT_TREE).authorizeInserter(address(testToken));
        console.log("Granted CommitmentTree permissions");

        // Mint tokens to test address
        address testUser = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        testToken.bridgeMint(testUser, 1000 ether);
        console.log("Minted 1000 tokens to:", testUser);

        // Also mint to deployer
        testToken.bridgeMint(deployer, 1000 ether);
        console.log("Minted 1000 tokens to deployer:", deployer);

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("VITE_GHOST_TOKEN_ADDRESS=%s", address(testToken));

        vm.stopBroadcast();
    }
}
