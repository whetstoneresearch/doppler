// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ICreateX } from "createx/ICreateX.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { StdConfig } from "forge-std/StdConfig.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { Versions } from "script/utils/Versions.sol";
import { DopplerCreateXDeployer } from "src/DopplerCreateXDeployer.sol";

abstract contract DeployBase is Script, Config, Versions {
    ICreateX internal constant CREATE_X = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    string internal constant DEPLOYMENTS_CONFIG_PATH = "./deployments.config.toml";
    string internal constant IS_TESTNET_KEY = "is_testnet";
    string internal constant PROTOCOL_DEPLOYER_KEY = "protocol_deployer";

    error Create2AddressMismatch(bytes32 salt, address expected, address computed);
    error Create3AddressMismatch(bytes32 salt, address expected, address computed);
    error InvalidCreateXGuardedSalt(bytes32 salt);
    error BroadcastSenderMismatch(address expected, address actual);

    struct DeployContext {
        uint256 chainId;
        StdConfig config;
        DopplerCreateXDeployer protocolDeployer;
        address broadcaster;
        bool writeConfig;
    }

    /// @notice Loads the shared deployments config for the chain selected by the caller.
    /// @dev Standalone scripts use this when the fork or RPC context is supplied by forge CLI arguments.
    function _loadConfigForCurrentChain() internal {
        _loadConfig(DEPLOYMENTS_CONFIG_PATH, true);
    }

    /// @notice Loads the shared deployments config and selects a fork for `chainId`.
    /// @dev Chain-specific aggregate scripts use this to run with baked-in defaults instead of CLI chain arguments.
    function _loadConfigAndSelectFork(uint256 chainId) internal {
        _loadConfig(DEPLOYMENTS_CONFIG_PATH, true);
        vm.createSelectFork(config.getRpcUrl(chainId));
        require(block.chainid == chainId, "Selected fork has unexpected chainId");
    }

    /// @notice Loads shared config, selects `chainId`, and checks its configured testnet flag.
    /// @dev Chain-specific script wrappers use this to keep baked-in chain targets honest.
    function _loadConfigAndSelectFork(uint256 chainId, bool expectedIsTestnet) internal {
        _loadConfigAndSelectFork(chainId);
        require(_isConfiguredTestnet(chainId) == expectedIsTestnet, "DeployBase testnet flag mismatch");
    }

    /// @notice Builds the common deployment context for scripts that deploy through the protocol deployer.
    /// @dev Resolves chain config, the protocol deployer address, broadcaster, and whether config writes are enabled.
    function _deployContext() internal returns (DeployContext memory context) {
        uint256 chainId = block.chainid;
        require(config.exists(chainId, PROTOCOL_DEPLOYER_KEY), "protocol_deployer is not configured");

        context = DeployContext({
            chainId: chainId,
            config: config,
            protocolDeployer: DopplerCreateXDeployer(config.get(chainId, PROTOCOL_DEPLOYER_KEY).toAddress()),
            broadcaster: _resolveBroadcastSender(),
            writeConfig: _shouldWriteConfig()
        });
    }

    /// @notice Returns whether the current script execution should persist deployment addresses to config.
    /// @dev Config writes are limited to broadcast runs so simulations and dry runs do not mutate local config.
    function _shouldWriteConfig() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
    }

    /// @notice Returns the configured testnet flag for `chainId`.
    function _isConfiguredTestnet(uint256 chainId) internal view returns (bool) {
        require(config.exists(chainId, IS_TESTNET_KEY), "is_testnet is not configured");
        return config.get(chainId, IS_TESTNET_KEY).toBool();
    }

    /// @notice Writes a chain-scoped address into the shared deployments config when writes are enabled.
    /// @dev Scripts using `DeployContext` use this to persist protocol contract addresses after deploy or reuse.
    function _setConfigAddress(DeployContext memory context, string memory key, address value) internal {
        if (context.writeConfig) {
            context.config.set(context.chainId, key, value);
        }
    }

    /// @notice Writes an address into the active config section when writes are enabled.
    /// @dev Bootstrap scripts use this before a `DeployContext` exists, such as when deploying the protocol deployer.
    function _setConfigAddress(string memory key, address value) internal {
        if (_shouldWriteConfig()) {
            config.set(key, value);
        }
    }

    /// @notice Deploys a contract through the protocol deployer or returns an existing deployment at `expected`.
    /// @dev Verifies the salt computes to `expected` before checking code or broadcasting to avoid trusting
    ///      unrelated occupied addresses. Callers are responsible for validating and recording the deployment.
    function _deployOrUseExistingCreate3(
        DeployContext memory context,
        bytes32 deploymentSalt,
        address expected,
        bytes memory initCode
    ) internal returns (address deployed, bool alreadyDeployed) {
        address computed = _computeProtocolCreate3Address(context.protocolDeployer, deploymentSalt);
        _verifyCreate3Address(deploymentSalt, expected, computed);

        if (expected.code.length != 0) {
            return (expected, true);
        }

        vm.startBroadcast();
        deployed = context.protocolDeployer.deployCreate3(deploymentSalt, initCode, expected);
        vm.stopBroadcast();

        _verifyCreate3Address(deploymentSalt, expected, deployed);
        return (deployed, false);
    }

    /// @notice Deploys a versioned contract through the protocol deployer.
    /// @dev `customSalt` and `customExpected` are optional, but must be provided together when either is set.
    function _deployOrUseExistingVersionedCreate3(
        DeployContext memory context,
        bytes32 customSalt,
        address customExpected,
        string memory contractName,
        uint8 version,
        bytes memory initCode
    ) internal returns (address deployed, bool alreadyDeployed) {
        _requireCompleteDeploymentConfig(customSalt, customExpected);

        bytes32 deploymentSalt =
            customSalt != bytes32(0) ? customSalt : context.protocolDeployer.generateSalt(contractName, version);
        address expected = customExpected != address(0)
            ? customExpected
            : _computeProtocolCreate3Address(context.protocolDeployer, deploymentSalt);

        return _deployOrUseExistingCreate3(context, deploymentSalt, expected, initCode);
    }

    /// @notice Deploys a bootstrap contract directly through CreateX CREATE2 or returns existing code at `expected`.
    /// @dev Used for contracts needed before the protocol deployer exists and mirrors CreateX guarded salt handling.
    ///      Callers are responsible for validating and recording the deployment.
    function _deployOrUseExistingCreateXCreate2(
        bytes32 deploymentSalt,
        address expected,
        bytes memory initCode
    ) internal returns (address deployed, bool alreadyDeployed) {
        address broadcaster = _resolveBroadcastSender();
        address computed = _computeCreateXCreate2Address(deploymentSalt, broadcaster, keccak256(initCode));
        _verifyCreate2Address(deploymentSalt, expected, computed);

        if (expected.code.length != 0) {
            return (expected, true);
        }

        vm.startBroadcast();
        _verifyBroadcastSender(broadcaster);
        deployed = CREATE_X.deployCreate2(deploymentSalt, initCode);
        vm.stopBroadcast();

        _verifyCreate2Address(deploymentSalt, expected, deployed);
        return (deployed, false);
    }

    /// @notice Reverts unless a computed or deployed CREATE2 address matches the expected address.
    function _verifyCreate2Address(bytes32 deploymentSalt, address expected, address computed) internal pure {
        if (computed != expected) {
            revert Create2AddressMismatch(deploymentSalt, expected, computed);
        }
    }

    /// @notice Reverts unless a computed or deployed CREATE3 address matches the expected address.
    /// @dev Centralizes the assurance that an overridden salt and expected address pair are internally consistent.
    function _verifyCreate3Address(bytes32 deploymentSalt, address expected, address computed) internal pure {
        if (computed != expected) {
            revert Create3AddressMismatch(deploymentSalt, expected, computed);
        }
    }

    /// @notice Reverts unless optional custom salt and expected-address overrides are complete.
    function _requireCompleteDeploymentConfig(bytes32 deploymentSalt, address expected) internal pure {
        require((deploymentSalt == bytes32(0)) == (expected == address(0)), "Deployment configuration is incomplete");
    }

    /// @notice Computes the CREATE3 address for a deployment sent through the protocol deployer.
    /// @dev Uses the protocol deployer's `computeGuardedSalt` wrapper because CreateX computes addresses from guarded salts.
    function _computeProtocolCreate3Address(
        DopplerCreateXDeployer protocolDeployer,
        bytes32 deploymentSalt
    ) internal view returns (address) {
        bytes32 guardedSalt = protocolDeployer.computeGuardedSalt(deploymentSalt);
        return CREATE_X.computeCreate3Address(guardedSalt);
    }

    /// @notice Computes the direct CreateX CREATE2 address for `deploymentSalt`, `caller`, and `initCodeHash`.
    /// @dev Used by bootstrap scripts that call CreateX directly instead of routing through the protocol deployer.
    function _computeCreateXCreate2Address(
        bytes32 deploymentSalt,
        address caller,
        bytes32 initCodeHash
    ) internal view returns (address) {
        return CREATE_X.computeCreate2Address(_computeCreateXGuardedSalt(deploymentSalt, caller), initCodeHash);
    }

    /// @notice Resolves the sender Foundry will use for default `vm.startBroadcast()` calls.
    /// @dev Starts and stops a broadcast section without external calls, so no transaction is recorded.
    function _resolveBroadcastSender() internal returns (address broadcaster) {
        vm.startBroadcast();
        (, broadcaster,) = vm.readCallers();
        vm.stopBroadcast();
    }

    /// @notice Reverts if the active broadcast sender differs from the sender used for address precomputation.
    function _verifyBroadcastSender(address expected) internal view {
        (VmSafe.CallerMode callerMode, address actual,) = vm.readCallers();
        if (callerMode != VmSafe.CallerMode.RecurrentBroadcast || actual != expected) {
            revert BroadcastSenderMismatch(expected, actual);
        }
    }

    /// @notice Computes the guarded salt that CreateX will derive from `deploymentSalt` for `caller`.
    /// @dev Mirrors CreateX salt-guard logic so scripts can preflight expected addresses before broadcasting.
    function _computeCreateXGuardedSalt(bytes32 deploymentSalt, address caller) internal view returns (bytes32) {
        address senderBytes = address(bytes20(deploymentSalt));
        bytes1 redeployProtectionFlag = deploymentSalt[20];

        if (senderBytes == caller) {
            if (redeployProtectionFlag == hex"00") {
                return _efficientHash({ a: bytes32(uint256(uint160(caller))), b: deploymentSalt });
            }
            if (redeployProtectionFlag == hex"01") {
                return keccak256(abi.encode(caller, block.chainid, deploymentSalt));
            }
            revert InvalidCreateXGuardedSalt(deploymentSalt);
        }

        if (senderBytes == address(0)) {
            if (redeployProtectionFlag == hex"01") {
                return _efficientHash({ a: bytes32(block.chainid), b: deploymentSalt });
            }
            if (redeployProtectionFlag != hex"00") {
                revert InvalidCreateXGuardedSalt(deploymentSalt);
            }
        }

        return deploymentSalt == _generatedCreateXSalt(caller) ? deploymentSalt : keccak256(abi.encode(deploymentSalt));
    }

    /// @notice Reconstructs the generated salt value CreateX recognizes for the current block context and caller.
    /// @dev Needed only to mirror CreateX's branch that skips hashing when the caller supplied its generated salt.
    function _generatedCreateXSalt(address caller) internal view returns (bytes32) {
        unchecked {
            return keccak256(
                abi.encode(
                    blockhash(block.number - 32),
                    block.coinbase,
                    block.number,
                    block.timestamp,
                    block.prevrandao,
                    block.chainid,
                    caller
                )
            );
        }
    }

    /// @notice Hashes two words using the same packed-memory pattern used by CreateX.
    /// @dev Keeps local guarded-salt computation byte-compatible with CreateX for sender and chain guarded salts.
    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }
}
