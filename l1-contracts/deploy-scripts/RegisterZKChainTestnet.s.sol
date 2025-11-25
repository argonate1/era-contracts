// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors, reason-string

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ADDRESS_ONE, Utils} from "./Utils.sol";
import {ContractsBytecodesLib} from "./ContractsBytecodesLib.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {Create2AndTransfer} from "./Create2AndTransfer.sol";

/// @title RegisterZKChainTestnet
/// @notice Simplified ZK Chain registration script for testnet deployments where owner is an EOA
/// @dev This bypasses the ChainAdminOwnable pattern used in production deployments
contract RegisterZKChainTestnet is Script {
    using stdToml for string;

    struct Config {
        address ownerAddress;
        uint256 chainChainId;
        bool validiumMode;
        uint256 bridgehubCreateNewChainSalt;
        address validatorSenderOperatorCommitEth;
        address validatorSenderOperatorBlobsEth;
        address baseToken;
        bytes32 baseTokenAssetId;
        uint128 baseTokenGasPriceMultiplierNominator;
        uint128 baseTokenGasPriceMultiplierDenominator;
        address bridgehub;
        address nativeTokenVault;
        address chainTypeManagerProxy;
        address validatorTimelock;
        bytes diamondCutData;
        bytes forceDeployments;
        address governanceSecurityCouncilAddress;
        uint256 governanceMinDelay;
        address create2FactoryAddress;
        bytes32 create2Salt;
    }

    struct Output {
        address governance;
        address diamondProxy;
        address chainAdmin;
        address chainProxyAdmin;
    }

    Config internal config;
    Output internal output;

    function run() public {
        console.log("Registering ZK Chain for Testnet (EOA owner)");

        initializeConfig();

        deployGovernance();
        deployChainAdmin();
        deployChainProxyAddress();

        // Register the ZK chain directly through bridgehub (as owner)
        registerZKChainDirect();

        addValidators();
        configureZkSyncStateTransition();
        setPendingAdmin();

        saveOutput();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/register-zk-chain.toml");
        string memory toml = vm.readFile(path);

        config.ownerAddress = toml.readAddress("$.owner_address");
        config.bridgehub = toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        config.chainTypeManagerProxy = toml.readAddress("$.deployed_addresses.state_transition.chain_type_manager_proxy_addr");
        config.validatorTimelock = toml.readAddress("$.deployed_addresses.validator_timelock_addr");
        config.nativeTokenVault = toml.readAddress("$.deployed_addresses.native_token_vault_addr");
        config.diamondCutData = toml.readBytes("$.contracts_config.diamond_cut_data");
        config.forceDeployments = toml.readBytes("$.contracts_config.force_deployments_data");
        config.create2FactoryAddress = toml.readAddress("$.create2_factory_address");
        config.create2Salt = toml.readBytes32("$.create2_salt");

        // Chain config
        config.chainChainId = toml.readUint("$.chain.chain_chain_id");
        config.baseToken = toml.readAddress("$.chain.base_token_addr");
        config.bridgehubCreateNewChainSalt = toml.readUint("$.chain.bridgehub_create_new_chain_salt");
        config.validiumMode = toml.readBool("$.chain.validium_mode");
        config.validatorSenderOperatorCommitEth = toml.readAddress("$.chain.validator_sender_operator_commit_eth");
        config.validatorSenderOperatorBlobsEth = toml.readAddress("$.chain.validator_sender_operator_blobs_eth");
        config.baseTokenGasPriceMultiplierNominator = uint128(toml.readUint("$.chain.base_token_gas_price_multiplier_nominator"));
        config.baseTokenGasPriceMultiplierDenominator = uint128(toml.readUint("$.chain.base_token_gas_price_multiplier_denominator"));
        config.governanceSecurityCouncilAddress = toml.readAddress("$.chain.governance_security_council_address");
        config.governanceMinDelay = toml.readUint("$.chain.governance_min_delay");

        // Get base token asset ID
        INativeTokenVault ntv = INativeTokenVault(config.nativeTokenVault);
        config.baseTokenAssetId = ntv.assetId(config.baseToken);

        console.log("Config loaded:");
        console.log("  Chain ID:", config.chainChainId);
        console.log("  Bridgehub:", config.bridgehub);
        console.log("  CTM:", config.chainTypeManagerProxy);
        console.log("  Base Token:", config.baseToken);
        console.log("  Base Token Asset ID:");
        console.logBytes32(config.baseTokenAssetId);
    }

    function deployGovernance() internal {
        bytes memory input = abi.encode(
            config.ownerAddress,
            config.governanceSecurityCouncilAddress,
            config.governanceMinDelay
        );
        address governance = Utils.deployViaCreate2(
            abi.encodePacked(type(Governance).creationCode, input),
            config.create2Salt,
            config.create2FactoryAddress
        );
        console.log("Governance deployed at:", governance);
        output.governance = governance;
    }

    function deployChainAdmin() internal {
        address chainAdmin = Utils.deployViaCreate2(
            abi.encodePacked(type(ChainAdminOwnable).creationCode, abi.encode(config.ownerAddress, address(0))),
            config.create2Salt,
            config.create2FactoryAddress
        );
        console.log("ChainAdminOwnable deployed at:", chainAdmin);
        output.chainAdmin = chainAdmin;
    }

    function deployChainProxyAddress() internal {
        bytes memory input = abi.encode(type(ProxyAdmin).creationCode, config.create2Salt, output.chainAdmin);
        bytes memory encoded = abi.encodePacked(type(Create2AndTransfer).creationCode, input);
        address create2AndTransfer = Utils.deployViaCreate2(encoded, config.create2Salt, config.create2FactoryAddress);

        address proxyAdmin = vm.computeCreate2Address(config.create2Salt, keccak256(encoded), create2AndTransfer);

        console.log("Transparent Proxy Admin deployed at:", address(proxyAdmin));
        output.chainProxyAdmin = address(proxyAdmin);
    }

    function registerZKChainDirect() internal {
        IBridgehub bridgehub = IBridgehub(config.bridgehub);

        console.log("Registering ZK Chain directly via bridgehub.createNewChain()");
        console.log("  Admin (pending):", msg.sender);

        bytes[] memory factoryDeps = getFactoryDeps();

        vm.broadcast(msg.sender);
        bridgehub.createNewChain(
            config.chainChainId,
            config.chainTypeManagerProxy,
            config.baseTokenAssetId,
            config.bridgehubCreateNewChainSalt,
            msg.sender, // pendingAdmin - will be changed later
            abi.encode(config.diamondCutData, config.forceDeployments),
            factoryDeps
        );

        console.log("ZK chain registration transaction sent");

        // Get new diamond proxy address
        address diamondProxyAddress = bridgehub.getZKChain(config.chainChainId);
        if (diamondProxyAddress == address(0)) {
            revert("Diamond proxy address not found after registration");
        }
        output.diamondProxy = diamondProxyAddress;
        console.log("ZKChain diamond proxy deployed at:", diamondProxyAddress);
    }

    function addValidators() internal {
        ValidatorTimelock validatorTimelock = ValidatorTimelock(config.validatorTimelock);

        vm.startBroadcast(msg.sender);
        validatorTimelock.addValidatorForChainId(config.chainChainId, config.validatorSenderOperatorCommitEth);
        validatorTimelock.addValidatorForChainId(config.chainChainId, config.validatorSenderOperatorBlobsEth);
        vm.stopBroadcast();

        console.log("Validators added:");
        console.log("  Commit operator:", config.validatorSenderOperatorCommitEth);
        console.log("  Blobs operator:", config.validatorSenderOperatorBlobsEth);
    }

    function configureZkSyncStateTransition() internal {
        IZKChain zkChain = IZKChain(output.diamondProxy);

        vm.startBroadcast(msg.sender);
        zkChain.setTokenMultiplier(
            config.baseTokenGasPriceMultiplierNominator,
            config.baseTokenGasPriceMultiplierDenominator
        );

        if (config.validiumMode) {
            zkChain.setPubdataPricingMode(PubdataPricingMode.Validium);
        }

        vm.stopBroadcast();
        console.log("ZkSync State Transition configured");
    }

    function setPendingAdmin() internal {
        IZKChain zkChain = IZKChain(output.diamondProxy);

        vm.startBroadcast(msg.sender);
        zkChain.setPendingAdmin(output.chainAdmin);
        vm.stopBroadcast();
        console.log("Pending admin set to:", output.chainAdmin);
    }

    function getFactoryDeps() internal view returns (bytes[] memory) {
        bytes[] memory factoryDeps = new bytes[](4);
        factoryDeps[0] = ContractsBytecodesLib.getCreationCode("BeaconProxy");
        factoryDeps[1] = ContractsBytecodesLib.getCreationCode("BridgedStandardERC20");
        factoryDeps[2] = ContractsBytecodesLib.getCreationCode("UpgradeableBeacon");
        factoryDeps[3] = ContractsBytecodesLib.getCreationCode("SystemTransparentUpgradeableProxy");
        return factoryDeps;
    }

    function saveOutput() internal {
        string memory root = vm.projectRoot();
        string memory outputPath = string.concat(root, "/script-out/output-register-zk-chain.toml");

        vm.serializeAddress("root", "diamond_proxy_addr", output.diamondProxy);
        vm.serializeAddress("root", "chain_admin_addr", output.chainAdmin);
        vm.serializeAddress("root", "chain_proxy_admin_addr", output.chainProxyAdmin);
        vm.serializeAddress("root", "access_control_restriction_addr", address(0));

        string memory toml = vm.serializeAddress("root", "governance_addr", output.governance);
        vm.writeToml(toml, outputPath);
        console.log("Output saved at:", outputPath);
    }
}
