// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { ChainIds } from "script/utils/ChainIds.sol";
import { UniswapV2MigratorSplit } from "src/migrators/UniswapV2MigratorSplit.sol";

abstract contract DeployUniV2MigratorSplit is DeployBase {
    function _deployUniV2MigratorSplit(DeployContext memory context) internal returns (address migrator) {
        address airlock = context.config.get(context.chainId, "airlock").toAddress();
        address topUpDistributor = context.config.get(context.chainId, "top_up_distributor").toAddress();
        return _deployUniV2MigratorSplit(context, airlock, topUpDistributor);
    }

    function _deployUniV2MigratorSplit(
        DeployContext memory context,
        address airlock,
        address topUpDistributor
    ) internal returns (address migrator) {
        address uniswapV2Factory = context.config.get(context.chainId, "uniswap_v2_factory").toAddress();
        address weth = context.config.get(context.chainId, "weth").toAddress();
        bytes memory initCode = abi.encodePacked(
            type(UniswapV2MigratorSplit).creationCode, abi.encode(airlock, uniswapV2Factory, topUpDistributor, weth)
        );

        bool alreadyDeployed;
        (migrator, alreadyDeployed) = _deployOrUseExistingVersionedCreate3(
            context,
            bytes32(0),
            address(0),
            type(UniswapV2MigratorSplit).name,
            UNISWAP_V2_MIGRATOR_SPLIT_VERSION,
            initCode
        );

        address locker =
            _verifyUniV2MigratorSplitDeployment(migrator, airlock, uniswapV2Factory, topUpDistributor, weth);
        _setConfigAddress(context, "uniswap_v2_migrator_split", migrator);
        _setConfigAddress(context, "uniswap_v2_locker", locker);

        if (alreadyDeployed) {
            console.log("UniswapV2MigratorSplit already deployed to:", migrator);
        } else {
            console.log("UniswapV2MigratorSplit deployed to:", migrator);
        }
        console.log("UniswapV2Locker deployed to:", locker);
    }

    function _verifyUniV2MigratorSplitDeployment(
        address addr,
        address airlock,
        address uniswapV2Factory,
        address topUpDistributor,
        address weth
    ) internal view returns (address locker) {
        UniswapV2MigratorSplit migrator = UniswapV2MigratorSplit(payable(addr));
        require(address(migrator.airlock()) == airlock, "UniswapV2MigratorSplit airlock mismatch");
        require(address(migrator.factory()) == uniswapV2Factory, "UniswapV2MigratorSplit factory mismatch");
        require(address(migrator.TOP_UP_DISTRIBUTOR()) == topUpDistributor, "UniswapV2MigratorSplit top-up mismatch");
        require(address(migrator.weth()) == weth, "UniswapV2MigratorSplit weth mismatch");

        locker = address(migrator.locker());
        require(locker != address(0) && locker.code.length != 0, "UniswapV2Locker missing");
    }
}

contract DeployUniV2MigratorSplitScript is DeployUniV2MigratorSplit {
    function setUp() public virtual {
        _loadConfigForCurrentChain();
    }

    function run() public virtual {
        deploy();
    }

    function deploy() public returns (address migrator) {
        return _deployUniV2MigratorSplit(_deployContext());
    }
}

contract DeployUniV2MigratorSplitScriptEthereum is DeployUniV2MigratorSplitScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.ETH_MAINNET, false);
    }
}

contract DeployUniV2MigratorSplitScriptMonad is DeployUniV2MigratorSplitScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.MONAD_MAINNET, false);
    }
}

contract DeployUniV2MigratorSplitScriptBase is DeployUniV2MigratorSplitScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_MAINNET, false);
    }
}

contract DeployUniV2MigratorSplitScriptBaseSepolia is DeployUniV2MigratorSplitScript {
    function setUp() public override {
        _loadConfigAndSelectFork(ChainIds.BASE_SEPOLIA, true);
    }
}
