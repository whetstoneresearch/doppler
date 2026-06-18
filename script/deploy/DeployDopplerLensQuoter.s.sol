// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { DopplerLensQuoter } from "src/lens/DopplerLens.sol";

abstract contract DeployDopplerLensQuoter is DeployBase {
    function _deployDopplerLensQuoter(DeployContext memory context) internal returns (address dopplerLensQuoter) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();
        address stateView = context.config.get(context.chainId, "uniswap_v4_state_view").toAddress();
        bytes memory initCode =
            abi.encodePacked(type(DopplerLensQuoter).creationCode, abi.encode(poolManager, stateView));

        bool alreadyDeployed;
        (dopplerLensQuoter, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(DopplerLensQuoter).name, DOPPLER_LENS_QUOTER_VERSION, initCode
        );

        _verifyDopplerLensQuoterDeployment(dopplerLensQuoter, poolManager, stateView);
        _setConfigAddress(context, "doppler_lens_quoter", dopplerLensQuoter);

        if (alreadyDeployed) {
            console.log("DopplerLensQuoter already deployed to:", dopplerLensQuoter);
        } else {
            console.log("DopplerLensQuoter deployed to:", dopplerLensQuoter);
        }
    }

    function _verifyDopplerLensQuoterDeployment(address addr, address poolManager, address stateView) internal view {
        DopplerLensQuoter quoter = DopplerLensQuoter(addr);
        require(address(quoter.poolManager()) == poolManager, "DopplerLensQuoter pool manager mismatch");
        require(address(quoter.stateView()) == stateView, "DopplerLensQuoter state view mismatch");
    }
}

contract DeployDopplerLensQuoterScript is DeployDopplerLensQuoter {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address dopplerLensQuoter) {
        return _deployDopplerLensQuoter(_deployContext());
    }
}

contract DeployDopplerLensQuoterScriptEthereum is DeployDopplerLensQuoterScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployDopplerLensQuoterScriptMonad is DeployDopplerLensQuoterScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployDopplerLensQuoterScriptBase is DeployDopplerLensQuoterScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployDopplerLensQuoterScriptBaseSepolia is DeployDopplerLensQuoterScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
