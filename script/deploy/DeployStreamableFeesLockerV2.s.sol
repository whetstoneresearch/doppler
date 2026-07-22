// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { StreamableFeesLockerV2 } from "src/lockers/StreamableFeesLockerV2.sol";

abstract contract DeployStreamableFeesLockerV2 is DeployBase {
    function _deployStreamableFeesLockerV2(DeployContext memory context) internal returns (address lockerV2) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();
        return _deployStreamableFeesLockerV2(
            context, poolManager, context.config.get(context.chainId, "airlock_multisig").toAddress()
        );
    }

    function _deployStreamableFeesLockerV2(
        DeployContext memory context,
        address owner
    ) internal returns (address lockerV2) {
        address poolManager = context.config.get(context.chainId, "uniswap_v4_pool_manager").toAddress();
        return _deployStreamableFeesLockerV2(context, poolManager, owner);
    }

    function _deployStreamableFeesLockerV2(
        DeployContext memory context,
        address poolManager,
        address owner
    ) internal returns (address lockerV2) {
        bytes memory initCode =
            abi.encodePacked(type(StreamableFeesLockerV2).creationCode, abi.encode(poolManager, owner));

        bool alreadyDeployed;
        (lockerV2, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context, bytes32(0), address(0), type(StreamableFeesLockerV2).name, STREAMABLE_FEES_LOCKER_VERSION, initCode
        );

        _verifyStreamableFeesLockerV2Deployment(lockerV2, poolManager, owner);
        _setConfigAddress(context, "streamable_fees_locker_v2", lockerV2);

        if (alreadyDeployed) {
            console.log("StreamableFeesLockerV2 already deployed to:", lockerV2);
        } else {
            console.log("StreamableFeesLockerV2 deployed to:", lockerV2);
        }
    }

    function _verifyStreamableFeesLockerV2Deployment(address addr, address poolManager, address owner) internal view {
        StreamableFeesLockerV2 locker = StreamableFeesLockerV2(payable(addr));
        require(address(locker.poolManager()) == poolManager, "StreamableFeesLockerV2 pool manager mismatch");
        require(locker.owner() == owner, "StreamableFeesLockerV2 owner mismatch");
    }
}

contract DeployStreamableFeesLockerV2Script is DeployStreamableFeesLockerV2 {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address lockerV2) {
        return _deployStreamableFeesLockerV2(_deployContext());
    }
}

contract DeployStreamableFeesLockerV2ScriptEthereum is DeployStreamableFeesLockerV2Script {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployStreamableFeesLockerV2ScriptMonad is DeployStreamableFeesLockerV2Script {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployStreamableFeesLockerV2ScriptBase is DeployStreamableFeesLockerV2Script {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployStreamableFeesLockerV2ScriptRobinhood is DeployStreamableFeesLockerV2Script {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ROBINHOOD_MAINNET, false);
    }
}

contract DeployStreamableFeesLockerV2ScriptBaseSepolia is DeployStreamableFeesLockerV2Script {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
