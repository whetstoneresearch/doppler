// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { TestDeployment } from "script/TestDeployment.s.sol";
import { DeployAirlock } from "script/deploy/DeployAirlock.s.sol";
import { DeployAirlockMultisigTestnet } from "script/deploy/DeployAirlockMultisigTestnet.s.sol";
import { DeployBundler } from "script/deploy/DeployBundler.s.sol";
import { DeployDN404Factory } from "script/deploy/DeployDN404Factory.s.sol";
import { DeployDopplerERC20V1Factory } from "script/deploy/DeployDopplerERC20V1Factory.s.sol";
import { DeployDopplerHookInitializer } from "script/deploy/DeployDopplerHookInitializer.s.sol";
import { DeployDopplerHookMigrator } from "script/deploy/DeployDopplerHookMigrator.s.sol";
import { DeployDopplerLensQuoter } from "script/deploy/DeployDopplerLensQuoter.s.sol";
import { DeployGovernanceFactory } from "script/deploy/DeployGovernanceFactory.s.sol";
import { DeployLaunchpadGovernanceFactory } from "script/deploy/DeployLaunchpadGovernanceFactory.s.sol";
import { DeployLockableUniswapV3Initializer } from "script/deploy/DeployLockableUniswapV3Initializer.s.sol";
import { DeployNoOpGovernanceFactory } from "script/deploy/DeployNoOpGovernanceFactory.s.sol";
import { DeployNoOpMigrator } from "script/deploy/DeployNoOpMigrator.s.sol";
import { DeployRehypeDopplerHookInitializer } from "script/deploy/DeployRehypeDopplerHookInitializer.s.sol";
import { DeployRehypeDopplerHookMigrator } from "script/deploy/DeployRehypeDopplerHookMigrator.s.sol";
import { DeployStreamableFeesLockerV2 } from "script/deploy/DeployStreamableFeesLockerV2.s.sol";
import { DeploySwapRestrictorDopplerHook } from "script/deploy/DeploySwapRestrictorDopplerHook.s.sol";
import { DeployTopUpDistributor } from "script/deploy/DeployTopUpDistributor.s.sol";
import { DeployUniV2MigratorSplit } from "script/deploy/DeployUniV2MigratorSplit.s.sol";
import { DeployUniswapV4Initializer } from "script/deploy/DeployUniswapV4Initializer.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";

contract DeployDopplerScript is
    DeployAirlock,
    DeployAirlockMultisigTestnet,
    DeployBundler,
    DeployTopUpDistributor,
    DeployStreamableFeesLockerV2,
    DeployDopplerERC20V1Factory,
    DeployDN404Factory,
    DeployNoOpGovernanceFactory,
    DeployGovernanceFactory,
    DeployLaunchpadGovernanceFactory,
    DeployLockableUniswapV3Initializer,
    DeployUniswapV4Initializer,
    DeployDopplerHookInitializer,
    DeployRehypeDopplerHookInitializer,
    DeploySwapRestrictorDopplerHook,
    DeployNoOpMigrator,
    DeployUniV2MigratorSplit,
    DeployDopplerHookMigrator,
    DeployRehypeDopplerHookMigrator,
    DeployDopplerLensQuoter,
    TestDeployment
{
    bool internal isTestnet;

    struct DeployedAddresses {
        address airlockMultisig;
        address airlock;
        address bundler;
        address dopplerERC20V1Factory;
        address noOpGovernanceFactory;
        address topUpDistributor;
        address streamableFeesLockerV2;
        address dopplerHookInitializer;
        address rehypeDopplerHookInitializer;
        address dopplerHookMigrator;
        address noOpMigrator;
    }

    function setUp() public virtual {
        _loadConfigForCurrentChain();
        isTestnet = _isConfiguredTestnet(block.chainid);
    }

    function run() public {
        DeployContext memory context = _deployContext();
        DeployedAddresses memory deployed;

        if (isTestnet) {
            deployed.airlockMultisig = _deployAirlockMultisigTestnet(context);
        } else {
            deployed.airlockMultisig = context.config.get(context.chainId, "airlock_multisig").toAddress();
        }

        deployed.airlock = _deployAirlock(context, deployed.airlockMultisig);
        deployed.topUpDistributor = _deployTopUpDistributor(context, deployed.airlock);
        deployed.streamableFeesLockerV2 = _deployStreamableFeesLockerV2(context, deployed.airlockMultisig);

        deployed.dopplerERC20V1Factory = _deployDopplerERC20V1Factory(context, deployed.airlock);
        _deployDN404Factory(context, deployed.airlock);

        deployed.noOpGovernanceFactory = _deployNoOpGovernanceFactory(context);
        _deployGovernanceFactory(context, deployed.airlock);
        _deployLaunchpadGovernanceFactory(context);

        _deployLockableUniswapV3Initializer(context, deployed.airlock);
        _deployUniswapV4Initializer(context, deployed.airlock);
        deployed.dopplerHookInitializer = _deployDopplerHookInitializer(context, deployed.airlock);
        deployed.bundler = _deployBundler(context, deployed.airlock);

        deployed.rehypeDopplerHookInitializer =
            _deployRehypeDopplerHookInitializer(context, deployed.dopplerHookInitializer, deployed.bundler);
        _deploySwapRestrictorDopplerHook(context, deployed.dopplerHookInitializer);

        deployed.noOpMigrator = _deployNoOpMigrator(context, deployed.airlock);
        _deployUniV2MigratorSplit(context, deployed.airlock, deployed.topUpDistributor);
        deployed.dopplerHookMigrator = _deployDopplerHookMigrator(
            context, deployed.airlock, deployed.topUpDistributor, deployed.streamableFeesLockerV2
        );
        _deployRehypeDopplerHookMigrator(context, deployed.dopplerHookMigrator);

        _deployDopplerLensQuoter(context);

        _testDeployment(
            deployed.airlock,
            deployed.bundler,
            deployed.dopplerERC20V1Factory,
            deployed.noOpGovernanceFactory,
            deployed.dopplerHookInitializer,
            deployed.rehypeDopplerHookInitializer,
            deployed.noOpMigrator
        );
    }

    function _setUpChain(uint256 chainId, bool _isTestnet) internal {
        _loadConfigAndSelectFork(chainId, _isTestnet);
        isTestnet = _isTestnet;
    }
}

contract DeployDopplerScriptEthereum is DeployDopplerScript {
    function setUp() public override {
        _setUpChain(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployDopplerScriptMonad is DeployDopplerScript {
    function setUp() public override {
        _setUpChain(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployDopplerScriptRobinhood is DeployDopplerScript {
    function setUp() public override {
        _setUpChain(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployDopplerScriptBase is DeployDopplerScript {
    function setUp() public override {
        _setUpChain(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployDopplerScriptArbitrum is DeployDopplerScript {
    function setUp() public override {
        _setUpChain(ChainIds.ARBITRUM_MAINNET, false);
    }
}

contract DeployDopplerScriptBaseSepolia is DeployDopplerScript {
    function setUp() public override {
        _setUpChain(ChainIds.BASE_SEPOLIA, true);
    }
}
