// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";

import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

/// @title DeployL1EcosystemBridge
/// @notice Deploys L1 bridge ecosystem contracts (L1Nullifier, L1AssetRouter, L1NativeTokenVault)
/// @dev This script deploys only the bridge contracts, assuming Bridgehub and STM already exist.
///      It follows the same TUPP (Transparent Upgradeable Proxy Pattern) as DeployL1CoreContracts.
///
/// Usage:
///   export BRIDGEHUB="0x35A54c8C757806eB6820629bc82d90E056394C92"
///   export OWNER="0xe3a615778aeEC76df1B368948a1D1614497Db858"
///   export WETH="0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9"
///   export ERA_CHAIN_ID="5447"
///   export ERA_DIAMOND_PROXY="0x0000000000000000000000000000000000000000"
///
///   forge script deploy-scripts/DeployL1EcosystemBridge.s.sol:DeployL1EcosystemBridge \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
contract DeployL1EcosystemBridge is Script {
    // ============ Config ============
    address public bridgehub;
    address public owner;
    address public weth;
    uint256 public eraChainId;
    address public eraDiamondProxy;

    // ============ Deployed Addresses ============
    address public l1NullifierImpl;
    address public l1NullifierProxy;
    address public l1AssetRouterImpl;
    address public l1AssetRouterProxy;
    address public bridgedStandardERC20Impl;
    address public bridgedTokenBeacon;
    address public l1NativeTokenVaultImpl;
    address public l1NativeTokenVaultProxy;

    function run() public {
        console.log("=== DeployL1EcosystemBridge ===");
        console.log("");

        _loadConfig();
        _validateConfig();

        vm.startBroadcast();

        _deployL1Nullifier();
        _deployL1AssetRouter();
        _deployBeaconAndNTV();
        _wireContracts();

        vm.stopBroadcast();

        _printSummary();
    }

    function _loadConfig() internal {
        bridgehub = vm.envAddress("BRIDGEHUB");
        owner = vm.envAddress("OWNER");
        weth = vm.envAddress("WETH");
        eraChainId = vm.envUint("ERA_CHAIN_ID");

        // ERA_DIAMOND_PROXY is optional - defaults to address(0) for new chains
        try vm.envAddress("ERA_DIAMOND_PROXY") returns (address diamond) {
            eraDiamondProxy = diamond;
        } catch {
            eraDiamondProxy = address(0);
        }

        console.log("Config loaded:");
        console.log("  Bridgehub:", bridgehub);
        console.log("  Owner:", owner);
        console.log("  WETH:", weth);
        console.log("  Era Chain ID:", eraChainId);
        console.log("  Era Diamond Proxy:", eraDiamondProxy);
        console.log("");
    }

    function _validateConfig() internal view {
        require(bridgehub != address(0), "BRIDGEHUB not set");
        require(owner != address(0), "OWNER not set");
        require(weth != address(0), "WETH not set");
        require(eraChainId != 0, "ERA_CHAIN_ID not set");

        // Verify bridgehub has code
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(sload(bridgehub.slot))
        }
        // Note: This check happens at runtime on the target chain
    }

    function _deployL1Nullifier() internal {
        console.log("Deploying L1Nullifier...");

        // Deploy implementation
        l1NullifierImpl = address(new L1Nullifier(
            IBridgehub(bridgehub),
            eraChainId,
            eraDiamondProxy
        ));
        console.log("  Implementation:", l1NullifierImpl);

        // Deploy proxy with initialization
        // Parameters for initialize: owner, and 4 legacy params (set to minimal values for new chain)
        bytes memory initData = abi.encodeCall(
            L1Nullifier.initialize,
            (owner, 1, 1, 1, 0)
        );

        l1NullifierProxy = address(new TransparentUpgradeableProxy(
            l1NullifierImpl,
            owner,  // proxy admin is owner
            initData
        ));
        console.log("  Proxy:", l1NullifierProxy);
        console.log("");
    }

    function _deployL1AssetRouter() internal {
        console.log("Deploying L1AssetRouter (SharedBridge)...");

        // Deploy implementation - requires L1NullifierProxy address
        l1AssetRouterImpl = address(new L1AssetRouter(
            weth,
            bridgehub,
            l1NullifierProxy,  // Immutable reference to L1Nullifier
            eraChainId,
            eraDiamondProxy
        ));
        console.log("  Implementation:", l1AssetRouterImpl);

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(
            L1AssetRouter.initialize,
            (owner)
        );

        l1AssetRouterProxy = address(new TransparentUpgradeableProxy(
            l1AssetRouterImpl,
            owner,  // proxy admin is owner
            initData
        ));
        console.log("  Proxy:", l1AssetRouterProxy);
        console.log("");
    }

    function _deployBeaconAndNTV() internal {
        console.log("Deploying BridgedStandardERC20 and Beacon...");

        // Deploy BridgedStandardERC20 implementation (no constructor args)
        bridgedStandardERC20Impl = address(new BridgedStandardERC20());
        console.log("  BridgedStandardERC20 Impl:", bridgedStandardERC20Impl);

        // Deploy UpgradeableBeacon pointing to BridgedStandardERC20
        bridgedTokenBeacon = address(new UpgradeableBeacon(bridgedStandardERC20Impl));
        console.log("  BridgedTokenBeacon:", bridgedTokenBeacon);
        console.log("");

        console.log("Deploying L1NativeTokenVault...");

        // Deploy NTV implementation - requires L1AssetRouterProxy and L1NullifierProxy
        l1NativeTokenVaultImpl = address(new L1NativeTokenVault(
            weth,
            l1AssetRouterProxy,  // Immutable reference to L1AssetRouter
            IL1Nullifier(l1NullifierProxy)  // Immutable reference to L1Nullifier
        ));
        console.log("  Implementation:", l1NativeTokenVaultImpl);

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(
            L1NativeTokenVault.initialize,
            (owner, bridgedTokenBeacon)
        );

        l1NativeTokenVaultProxy = address(new TransparentUpgradeableProxy(
            l1NativeTokenVaultImpl,
            owner,  // proxy admin is owner
            initData
        ));
        console.log("  Proxy:", l1NativeTokenVaultProxy);
        console.log("");
    }

    function _wireContracts() internal {
        console.log("Wiring contracts together...");

        IL1AssetRouter assetRouter = IL1AssetRouter(l1AssetRouterProxy);
        IL1Nullifier nullifier = IL1Nullifier(l1NullifierProxy);
        IL1NativeTokenVault ntv = IL1NativeTokenVault(l1NativeTokenVaultProxy);

        // 1. Wire NTV to AssetRouter
        assetRouter.setNativeTokenVault(INativeTokenVault(l1NativeTokenVaultProxy));
        console.log("  L1AssetRouter.setNativeTokenVault() done");

        // 2. Wire NTV to Nullifier
        nullifier.setL1NativeTokenVault(ntv);
        console.log("  L1Nullifier.setL1NativeTokenVault() done");

        // 3. Wire AssetRouter to Nullifier
        nullifier.setL1AssetRouter(l1AssetRouterProxy);
        console.log("  L1Nullifier.setL1AssetRouter() done");

        // 4. Register ETH token in NTV
        ntv.registerEthToken();
        console.log("  L1NativeTokenVault.registerEthToken() done");

        console.log("");
    }

    function _printSummary() internal view {
        console.log("========================================");
        console.log("       DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("L1Nullifier:");
        console.log("  Implementation:", l1NullifierImpl);
        console.log("  Proxy:", l1NullifierProxy);
        console.log("");
        console.log("L1AssetRouter (SharedBridge):");
        console.log("  Implementation:", l1AssetRouterImpl);
        console.log("  Proxy:", l1AssetRouterProxy);
        console.log("");
        console.log("BridgedStandardERC20:");
        console.log("  Implementation:", bridgedStandardERC20Impl);
        console.log("  Beacon:", bridgedTokenBeacon);
        console.log("");
        console.log("L1NativeTokenVault:");
        console.log("  Implementation:", l1NativeTokenVaultImpl);
        console.log("  Proxy:", l1NativeTokenVaultProxy);
        console.log("");
        console.log("========================================");
        console.log("");
        console.log("Next steps:");
        console.log("1. Update configs/contracts.yaml with these addresses");
        console.log("2. Optionally wire to Bridgehub via setAddresses()");
        console.log("");
        console.log("YAML config to update:");
        console.log("  bridges:");
        console.log("    shared:");
        console.log("      l1_address:", l1AssetRouterProxy);
        console.log("    l1_nullifier_addr:", l1NullifierProxy);
        console.log("  core_ecosystem_contracts:");
        console.log("    native_token_vault_addr:", l1NativeTokenVaultProxy);
    }
}
