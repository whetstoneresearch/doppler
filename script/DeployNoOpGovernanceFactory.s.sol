// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { ICreateX } from "script/ICreateX.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { computeCreate3Address, efficientHash } from "test/shared/AirlockMiner.sol";

contract DeployNoOpGovernanceFactoryScript is Script, Config {
    function run() public {
        _loadConfigAndForks("./deployments.config.toml", true);

        for (uint256 i; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Right now we're only deploying to MegaETH chains since Airlock is already deployed on others
            // MegaETH Mainnet 4326
            // MegaETH Testnet 6343
            if (chainId == 6343 || chainId == 4326) {
                deployToChain(chainId);
            }
        }
    }

    function deployToChain(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);

        address createX = config.get("create_x").toAddress();

        vm.startBroadcast();
        bytes32 salt = bytes32((uint256(uint160(msg.sender)) << 96) + uint256(0xdeadb055deadb055));
        bytes32 guardedSalt = efficientHash({ a: bytes32(uint256(uint160(msg.sender))), b: salt });

        address predictedAddress = computeCreate3Address(guardedSalt, createX);

        address noOpGovernanceFactory =
            ICreateX(createX).deployCreate3(salt, abi.encodePacked(type(NoOpGovernanceFactory).creationCode));
        require(noOpGovernanceFactory == predictedAddress, "Unexpected deployed address");

        console.log("NoOpGovernanceFactory deployed to:", noOpGovernanceFactory);
        config.set("no_op_governance_factory", noOpGovernanceFactory);
        vm.stopBroadcast();
    }
}

struct ScriptData {
    uint256 chainId;
    address airlock;
}

abstract contract DeployNoOpGovernanceFactoryScriptBase is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        require(_scriptData.chainId == block.chainid, "Invalid chainId");
        console.log(unicode"🚀 Deploying on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        NoOpGovernanceFactory noOpGovernanceFactory = new NoOpGovernanceFactory();

        console.log(unicode"✨ NoOpGovernanceFactory was successfully deployed!");
        console.log("NoOpGovernanceFactory address: %s", address(noOpGovernanceFactory));

        vm.stopBroadcast();
    }
}

contract DeployNoOpGovernanceFactoryBaseScript is DeployNoOpGovernanceFactoryScriptBase {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12, chainId: ChainIds.BASE_MAINNET });
    }
}

contract DeployNoOpGovernanceFactoryBaseSepoliaScript is DeployNoOpGovernanceFactoryScriptBase {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e, chainId: ChainIds.BASE_SEPOLIA });
    }
}

/// @dev forge script DeployNoOpGovernanceFactoryUnichainScript --private-key $PRIVATE_KEY --verify --rpc-url $UNICHAIN_MAINNET_RPC_URL --slow --broadcast
contract DeployNoOpGovernanceFactoryUnichainScript is DeployNoOpGovernanceFactoryScriptBase {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254, chainId: ChainIds.UNICHAIN_MAINNET });
    }
}

/// @dev forge script DeployNoOpGovernanceFactoryUnichainSepolia --private-key $PRIVATE_KEY --verify --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --slow --broadcast
contract DeployNoOpGovernanceFactoryUnichainSepolia is DeployNoOpGovernanceFactoryScriptBase {
    function setUp() public override {
        _scriptData =
            ScriptData({ airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF, chainId: ChainIds.UNICHAIN_SEPOLIA });
    }
}
