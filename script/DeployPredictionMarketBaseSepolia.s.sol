// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Config } from "forge-std/Config.sol";
import { Script, console } from "forge-std/Script.sol";
import { ChainIds } from "script/ChainIds.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import { MockPredictionOracle } from "src/base/MockPredictionOracle.sol";
import { NoSellDopplerHook } from "src/dopplerHooks/NoSellDopplerHook.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { PredictionMigrator } from "src/migrators/PredictionMigrator.sol";
import { AirlockMultisigTestnet } from "script/utils/AirlockMultisigTestnet.sol";

/// @notice Deploys prediction market modules on Base Sepolia reusing existing protocol addresses from config.
/// @dev Usage:
/// forge script script/DeployPredictionMarketBaseSepolia.s.sol:DeployPredictionMarketBaseSepoliaScript \
///   --rpc-url $BASE_SEPOLIA_RPC_URL \
///   --private-key $PRIVATE_KEY \
///   --verify \
///   --slow \
///   --broadcast
/// @dev Optional signature to skip the mock oracle deployment:
/// --sig "run(bool)" false
contract DeployPredictionMarketBaseSepoliaScript is Script, Config {
    struct ExistingAddresses {
        address airlock;
        address airlockMultisig;
        address dopplerHookInitializer;
        address tokenFactory;
        address governanceFactory;
    }

    struct Deployment {
        address predictionMigrator;
        address noSellDopplerHook;
        address mockPredictionOracle;
    }

    function run() external {
        run(true);
    }

    function run(bool deployMockOracle) public {
        require(block.chainid == ChainIds.BASE_SEPOLIA, "This script targets Base Sepolia only");
        _loadConfig("./deployments.config.toml", true);

        ExistingAddresses memory existing = ExistingAddresses({
            airlock: config.get("airlock").toAddress(),
            airlockMultisig: config.get("airlock_multisig").toAddress(),
            dopplerHookInitializer: config.get("doppler_hook_initializer").toAddress(),
            tokenFactory: config.get("clone_erc20_factory").toAddress(),
            governanceFactory: config.get("no_op_governance_factory").toAddress()
        });

        _validateExistingAddresses(existing);
        _logExistingAddresses(existing);

        vm.startBroadcast();
        address predictionMigrator = address(new PredictionMigrator(existing.airlock));
        address noSellDopplerHook = address(new NoSellDopplerHook(existing.dopplerHookInitializer));
        address mockPredictionOracle = deployMockOracle ? address(new MockPredictionOracle()) : address(0);
        vm.stopBroadcast();

        Deployment memory deployed = Deployment({
            predictionMigrator: predictionMigrator,
            noSellDopplerHook: noSellDopplerHook,
            mockPredictionOracle: mockPredictionOracle
        });

        _configureProtocolIfAuthorized(existing, deployed);
        _persistToConfig(deployed, deployMockOracle);
        _logDeployedAddresses(deployed);
    }

    function _validateExistingAddresses(ExistingAddresses memory existing) internal view {
        require(existing.airlock != address(0), "Missing config: airlock");
        require(existing.airlockMultisig != address(0), "Missing config: airlock_multisig");
        require(existing.dopplerHookInitializer != address(0), "Missing config: doppler_hook_initializer");
        require(existing.tokenFactory != address(0), "Missing config: clone_erc20_factory");
        require(existing.governanceFactory != address(0), "Missing config: no_op_governance_factory");
        require(existing.airlock.code.length > 0, "Configured airlock is not deployed");
        require(existing.dopplerHookInitializer.code.length > 0, "Configured doppler_hook_initializer is not deployed");
        require(existing.tokenFactory.code.length > 0, "Configured clone_erc20_factory is not deployed");
        require(existing.governanceFactory.code.length > 0, "Configured no_op_governance_factory is not deployed");
    }

    function _configureProtocolIfAuthorized(ExistingAddresses memory existing, Deployment memory deployed) internal {
        Airlock airlock = Airlock(payable(existing.airlock));
        address owner = airlock.owner();
        uint256 hookFlags = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;

        address[] memory modules = new address[](1);
        modules[0] = deployed.predictionMigrator;
        ModuleState[] memory moduleStates = new ModuleState[](1);
        moduleStates[0] = ModuleState.LiquidityMigrator;

        address[] memory hooks = new address[](1);
        hooks[0] = deployed.noSellDopplerHook;
        uint256[] memory flags = new uint256[](1);
        flags[0] = hookFlags;

        if (owner == msg.sender) {
            vm.startBroadcast();
            airlock.setModuleState(modules, moduleStates);
            DopplerHookInitializer(payable(existing.dopplerHookInitializer)).setDopplerHookState(hooks, flags);
            vm.stopBroadcast();
            console.log(unicode"✅ PredictionMigrator whitelisted and NoSellDopplerHook enabled by Airlock owner.");
            return;
        }

        bool signer = _isMultisigSigner(existing.airlockMultisig, msg.sender);
        if (owner == existing.airlockMultisig && signer) {
            vm.startBroadcast();
            AirlockMultisigTestnet(existing.airlockMultisig).setModuleState(
                payable(existing.airlock), modules, moduleStates
            );
            AirlockMultisigTestnet(existing.airlockMultisig).setDopplerHookState(
                payable(existing.dopplerHookInitializer), hooks, flags
            );
            vm.stopBroadcast();
            console.log(unicode"✅ PredictionMigrator whitelisted and NoSellDopplerHook enabled via Airlock multisig.");
            return;
        }

        console.log(unicode"⚠️  Admin setup skipped:");
        console.log("  Airlock owner: %s", owner);
        console.log("  Sender: %s", msg.sender);
        console.log("  Multisig signer: %s", signer);
        console.log(
            "  Run either WhitelistSingleModuleScript (state=4) and setDopplerHookState, or rerun as owner/multisig signer."
        );
    }

    function _isMultisigSigner(address multisig, address signer) internal view returns (bool) {
        if (multisig.code.length == 0) {
            return false;
        }
        try AirlockMultisigTestnet(multisig).isSigner(signer) returns (bool isSigner) {
            return isSigner;
        } catch {
            return false;
        }
    }

    function _persistToConfig(Deployment memory deployed, bool deployMockOracle) internal {
        config.set("prediction_migrator", deployed.predictionMigrator);
        config.set("no_sell_doppler_hook", deployed.noSellDopplerHook);
        if (deployMockOracle) {
            config.set("mock_prediction_oracle", deployed.mockPredictionOracle);
        }
    }

    function _logExistingAddresses(ExistingAddresses memory existing) internal pure {
        console.log(unicode"📦 Reusing existing Base Sepolia contracts");
        console.log("  Airlock: %s", existing.airlock);
        console.log("  AirlockMultisigTestnet: %s", existing.airlockMultisig);
        console.log("  DopplerHookInitializer: %s", existing.dopplerHookInitializer);
        console.log("  CloneERC20Factory: %s", existing.tokenFactory);
        console.log("  NoOpGovernanceFactory: %s", existing.governanceFactory);
    }

    function _logDeployedAddresses(Deployment memory deployed) internal pure {
        console.log(unicode"🚀 Prediction market deployment complete");
        console.log("  PredictionMigrator: %s", deployed.predictionMigrator);
        console.log("  NoSellDopplerHook: %s", deployed.noSellDopplerHook);
        if (deployed.mockPredictionOracle != address(0)) {
            console.log("  MockPredictionOracle: %s", deployed.mockPredictionOracle);
        } else {
            console.log("  MockPredictionOracle: skipped");
        }
        console.log("  NOTE: Existing pool/token/governance factories are reused from deployments.config.toml");
    }
}
