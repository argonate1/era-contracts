// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console

import {Script, console2 as console} from "forge-std/Script.sol";
import {TestnetERC20Token} from "contracts/dev-contracts/TestnetERC20Token.sol";

/// @title DeployGhostToken
/// @notice Deploys the Ghostcoin (GHOST) token for Umbraline L2
/// @dev GHOST is the native gas token for the Umbraline chain
contract DeployGhostToken is Script {
    // Token parameters
    string constant TOKEN_NAME = "Ghostcoin";
    string constant TOKEN_SYMBOL = "GHOST";
    uint8 constant TOKEN_DECIMALS = 18;

    // Total supply: 1 billion tokens
    uint256 constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    function run() public {
        // Get deployer address from msg.sender when using --private-key flag
        address deployer = msg.sender;

        console.log("=== Deploying Ghostcoin (GHOST) Token ===");
        console.log("Deployer address:", deployer);
        console.log("Total supply:", TOTAL_SUPPLY / 10**18, "GHOST");

        vm.startBroadcast();

        // Deploy GHOST token using TestnetERC20Token
        TestnetERC20Token ghost = new TestnetERC20Token(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        console.log("GHOST Token deployed at:", address(ghost));

        // Mint total supply to deployer
        bool success = ghost.mint(deployer, TOTAL_SUPPLY);
        require(success, "Minting failed");

        console.log("Minted", TOTAL_SUPPLY / 10**18, "GHOST to deployer");

        vm.stopBroadcast();

        // Verification
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Token Name:", ghost.name());
        console.log("Token Symbol:", ghost.symbol());
        console.log("Token Decimals:", ghost.decimals());
        console.log("Token Address:", address(ghost));
        console.log("Deployer Balance:", ghost.balanceOf(deployer) / 10**18, "GHOST");
        console.log("");
        console.log("IMPORTANT: Save the GHOST token address for chain creation:");
        console.log("  export GHOST_TOKEN_ADDRESS=", address(ghost));
    }

    // Exclude from coverage report
    function test() internal {}
}
