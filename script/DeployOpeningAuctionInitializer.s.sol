/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Script, console } from "forge-std/Script.sol";
import { OpeningAuctionInitializer, OpeningAuctionDeployer, IDopplerDeployer } from "src/OpeningAuctionInitializer.sol";
import { OpeningAuctionPositionManager } from "src/periphery/OpeningAuctionPositionManager.sol";
import { DopplerDeployer } from "src/initializers/UniswapV4Initializer.sol";

struct ScriptData {
    address airlock;
    address poolManager;
    address dopplerDeployer; // Optional: set to address(0) to deploy a new one
    address positionManager; // Optional: set to address(0) to deploy a new one
}

/**
 * @title Opening Auction Initializer Deployment Script
 * @notice Deploys OpeningAuctionDeployer and OpeningAuctionInitializer
 */
abstract contract DeployOpeningAuctionInitializerScript is Script {
    ScriptData internal _scriptData;

    function setUp() public virtual;

    function run() public {
        console.log(unicode"🚀 Deploying OpeningAuctionInitializer on chain %s with sender %s...", vm.toString(block.chainid), msg.sender);

        vm.startBroadcast();

        // Deploy OpeningAuctionDeployer
        OpeningAuctionDeployer auctionDeployer = new OpeningAuctionDeployer(IPoolManager(_scriptData.poolManager));
        console.log("OpeningAuctionDeployer deployed at:", address(auctionDeployer));

        // Use existing DopplerDeployer or deploy a new one
        IDopplerDeployer dopplerDeployer;
        if (_scriptData.dopplerDeployer != address(0)) {
            dopplerDeployer = IDopplerDeployer(_scriptData.dopplerDeployer);
            console.log("Using existing DopplerDeployer at:", _scriptData.dopplerDeployer);
        } else {
            DopplerDeployer newDopplerDeployer = new DopplerDeployer(IPoolManager(_scriptData.poolManager));
            dopplerDeployer = IDopplerDeployer(address(newDopplerDeployer));
            console.log("DopplerDeployer deployed at:", address(newDopplerDeployer));
        }

        // Use existing PositionManager or deploy a new one
        address positionManager;
        if (_scriptData.positionManager != address(0)) {
            positionManager = _scriptData.positionManager;
            console.log("Using existing PositionManager at:", positionManager);
        } else {
            OpeningAuctionPositionManager newPositionManager = new OpeningAuctionPositionManager(
                IPoolManager(_scriptData.poolManager)
            );
            positionManager = address(newPositionManager);
            console.log("PositionManager deployed at:", positionManager);
        }

        // Deploy OpeningAuctionInitializer
        OpeningAuctionInitializer initializer = new OpeningAuctionInitializer(
            _scriptData.airlock,
            IPoolManager(_scriptData.poolManager),
            auctionDeployer,
            dopplerDeployer,
            positionManager
        );
        console.log("OpeningAuctionInitializer deployed at:", address(initializer));

        vm.stopBroadcast();
    }
}

/// @dev forge script DeployOpeningAuctionInitializerBaseScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_MAINNET_RPC_URL
contract DeployOpeningAuctionInitializerBaseScript is DeployOpeningAuctionInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12,
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            dopplerDeployer: address(0), // Deploy new DopplerDeployer
            positionManager: address(0) // Deploy new PositionManager
        });
    }
}

/// @dev forge script DeployOpeningAuctionInitializerBaseSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $BASE_SEPOLIA_RPC_URL
contract DeployOpeningAuctionInitializerBaseSepoliaScript is DeployOpeningAuctionInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            dopplerDeployer: address(0), // Deploy new DopplerDeployer
            positionManager: address(0) // Deploy new PositionManager
        });
    }
}

/// @dev forge script DeployOpeningAuctionInitializerUnichainScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_MAINNET_RPC_URL
contract DeployOpeningAuctionInitializerUnichainScript is DeployOpeningAuctionInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
            poolManager: 0x1F98400000000000000000000000000000000004,
            dopplerDeployer: address(0), // Deploy new DopplerDeployer
            positionManager: address(0) // Deploy new PositionManager
        });
    }
}

/// @dev forge script DeployOpeningAuctionInitializerUnichainSepoliaScript --private-key $PRIVATE_KEY --verify --slow --broadcast --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
contract DeployOpeningAuctionInitializerUnichainSepoliaScript is DeployOpeningAuctionInitializerScript {
    function setUp() public override {
        _scriptData = ScriptData({
            airlock: 0x0d2f38d807bfAd5C18e430516e10ab560D300caF,
            poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
            dopplerDeployer: address(0), // Deploy new DopplerDeployer
            positionManager: address(0) // Deploy new PositionManager
        });
    }
}
