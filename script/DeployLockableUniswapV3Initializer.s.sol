/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { ChainIds } from "script/ChainIds.sol";
import { LibString } from "solady/utils/LibString.sol";
import { LockableUniswapV3Initializer } from "src/initializers/LockableUniswapV3Initializer.sol";

struct ScriptData {
    address airlock;
    address uniswapV3Factory;
    uint256 chainId;
}

abstract contract DeployLockableUniswapV3InitializerScript is Script, Config {
    ScriptData internal _scriptData;

    function setUp() public virtual {
        _loadConfigAndForks("./deployments.config.toml", true);
    }

    function run() public {
        vm.startBroadcast();
        LockableUniswapV3Initializer initializer =
            new LockableUniswapV3Initializer(_scriptData.airlock, IUniswapV3Factory(_scriptData.uniswapV3Factory));
        vm.stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            config.set("lockable_uniswap_v3_initializer", address(initializer));
        }
        console.log(
            "LockableUniswapV3Initializer was deployed to",
            LibString.toHexString(uint256(uint160(address(initializer)))),
            "on chain ID",
            LibString.toString(_scriptData.chainId)
        );
    }
}

/// @dev forge script DeployLockableUniswapV3InitializerEthereumMainnet --private-key $PRIVATE_KEY --verify --slow --broadcast
contract DeployLockableUniswapV3InitializerEthereumMainnet is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        super.setUp();
        vm.selectFork(forkOf[ChainIds.ETH_MAINNET]);
        _scriptData = ScriptData({
            airlock: config.get("airlock").toAddress(),
            uniswapV3Factory: config.get("uniswap_v3_factory").toAddress(),
            chainId: ChainIds.ETH_MAINNET
        });
    }
}

/// @dev forge script DeployLockableUniswapV3InitializerBaseSepolia --private-key $PRIVATE_KEY --verify --slow --broadcast
contract DeployLockableUniswapV3InitializerBaseSepolia is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        super.setUp();
        vm.selectFork(forkOf[ChainIds.BASE_SEPOLIA]);
        _scriptData = ScriptData({
            airlock: config.get("airlock").toAddress(),
            uniswapV3Factory: config.get("uniswap_v3_factory").toAddress(),
            chainId: ChainIds.BASE_SEPOLIA
        });
    }
}

/// @dev forge script DeployLockableUniswapV3InitializerBase --private-key $PRIVATE_KEY --verify --slow --broadcast
contract DeployLockableUniswapV3InitializerBase is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        super.setUp();
        vm.selectFork(forkOf[ChainIds.BASE_MAINNET]);
        _scriptData = ScriptData({
            airlock: config.get("airlock").toAddress(),
            uniswapV3Factory: config.get("uniswap_v3_factory").toAddress(),
            chainId: ChainIds.BASE_MAINNET
        });
    }
}

/// @dev forge script DeployLockableUniswapV3InitializerUnichainSepolia --private-key $PRIVATE_KEY --verify --slow --broadcast
contract DeployLockableUniswapV3InitializerUnichainSepolia is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        super.setUp();
        vm.selectFork(forkOf[ChainIds.UNICHAIN_SEPOLIA]);
        _scriptData = ScriptData({
            airlock: config.get("airlock").toAddress(),
            uniswapV3Factory: config.get("uniswap_v3_factory").toAddress(),
            chainId: ChainIds.UNICHAIN_SEPOLIA
        });
    }
}

/// @dev forge script DeployLockableUniswapV3InitializerUnichain --private-key $PRIVATE_KEY --verify --slow --broadcast
contract DeployLockableUniswapV3InitializerUnichain is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        super.setUp();
        vm.selectFork(forkOf[ChainIds.UNICHAIN_MAINNET]);
        _scriptData = ScriptData({
            airlock: config.get("airlock").toAddress(),
            uniswapV3Factory: config.get("uniswap_v3_factory").toAddress(),
            chainId: ChainIds.UNICHAIN_MAINNET
        });
    }
}

/// @dev forge script DeployLockableUniswapV3InitializerMonad --private-key $PRIVATE_KEY --verify --slow --broadcast
contract DeployLockableUniswapV3InitializerMonad is DeployLockableUniswapV3InitializerScript {
    function setUp() public override {
        super.setUp();
        vm.selectFork(forkOf[ChainIds.MONAD_MAINNET]);
        _scriptData = ScriptData({
            airlock: config.get("airlock").toAddress(),
            uniswapV3Factory: config.get("uniswap_v3_factory").toAddress(),
            chainId: ChainIds.MONAD_MAINNET
        });
    }
}
