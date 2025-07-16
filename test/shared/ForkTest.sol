// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { BaseForkTest } from "./BaseForkTest.sol";
import { console } from "forge-std/console.sol";
import { CreateParams, ModuleState } from "src/Airlock.sol";
import { InitData } from "src/UniswapV3Initializer.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { WETH_BASE } from "test/shared/Addresses.sol";

contract ForkTest is BaseForkTest {
    
    function testAirlockDeployment() public {
        assertNotEq(address(airlock), address(0));
        assertEq(airlock.owner(), impersonatedAddress);
    }
    
    function testNoOpVsFullGovernance() public {
        console.log("\n=== Testing NoOp vs Full Governance Behavior ===");
        
        // Deploy with NoOp governance
        bytes memory tokenData = _encodeTokenData("NoOp Test", "NOOP");
        CreateParams memory noOpParams = CreateParams({
            initialSupply: 1_000_000 * 1e18,
            numTokensToSell: 10_000 * 1e18,
            numeraire: WETH_BASE,
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenData,
            governanceFactory: noOpGovernanceFactory,
            governanceFactoryData: "",
            poolInitializer: v3Initializer,
            poolInitializerData: abi.encode(InitData({
                fee: 3000,
                tickLower: 46080,
                tickUpper: 92160,
                numPositions: 1,
                maxShareToBeSold: 1e17
            })),
            liquidityMigrator: v2Migrator,
            liquidityMigratorData: "",
            integrator: impersonatedAddress,
            salt: bytes32(uint256(100))
        });
        
        (address noOpAsset, , address noOpGovernance, address noOpTimelock, ) = airlock.create(noOpParams);
        
        // Deploy with full governance
        tokenData = _encodeTokenData("Full Gov Test", "FULL");
        bytes memory governanceData = abi.encode("Test Governor", 1, 100, 0);
        CreateParams memory fullParams = CreateParams({
            initialSupply: 1_000_000 * 1e18,
            numTokensToSell: 10_000 * 1e18,
            numeraire: WETH_BASE,
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenData,
            governanceFactory: governanceFactory,
            governanceFactoryData: governanceData,
            poolInitializer: v3Initializer,
            poolInitializerData: abi.encode(InitData({
                fee: 3000,
                tickLower: 46080,
                tickUpper: 92160,
                numPositions: 1,
                maxShareToBeSold: 1e17
            })),
            liquidityMigrator: v2Migrator,
            liquidityMigratorData: "",
            integrator: impersonatedAddress,
            salt: bytes32(uint256(101))
        });
        
        (address fullAsset, , address fullGovernance, address fullTimelock, ) = airlock.create(fullParams);
        
        // Verify NoOp returns dead addresses
        console.log("\nNoOp Governance results:");
        console.log("- Governance:", noOpGovernance);
        console.log("- Timelock:", noOpTimelock);
        assertEq(noOpGovernance, address(0xdEaD), "NoOp should return dead address for governance");
        assertEq(noOpTimelock, address(0xdEaD), "NoOp should return dead address for timelock");
        
        // Verify Full governance returns real contracts
        console.log("\nFull Governance results:");
        console.log("- Governance:", fullGovernance);
        console.log("- Timelock:", fullTimelock);
        assertNotEq(fullGovernance, address(0), "Full governance should return valid address");
        assertNotEq(fullGovernance, address(0xdEaD), "Full governance should not return dead address");
        assertNotEq(fullTimelock, address(0), "Full timelock should return valid address");
        assertNotEq(fullTimelock, address(0xdEaD), "Full timelock should not return dead address");
        
        console.log("\n[SUCCESS] Governance behavior verified!");
    }
    
    function testModuleDeployments() public {
        // Test all modules are deployed
        assertNotEq(address(tokenFactory), address(0));
        assertNotEq(address(governanceFactory), address(0));
        assertNotEq(address(noOpGovernanceFactory), address(0));
        assertNotEq(address(v3Initializer), address(0));
        assertNotEq(address(v4Initializer), address(0));
        assertNotEq(address(v2Migrator), address(0));
        
        // Test module registration
        assertEq(uint256(airlock.getModuleState(address(tokenFactory))), uint256(ModuleState.TokenFactory));
        assertEq(uint256(airlock.getModuleState(address(governanceFactory))), uint256(ModuleState.GovernanceFactory));
        assertEq(uint256(airlock.getModuleState(address(noOpGovernanceFactory))), uint256(ModuleState.GovernanceFactory));
        assertEq(uint256(airlock.getModuleState(address(v3Initializer))), uint256(ModuleState.PoolInitializer));
        assertEq(uint256(airlock.getModuleState(address(v4Initializer))), uint256(ModuleState.PoolInitializer));
        assertEq(uint256(airlock.getModuleState(address(v2Migrator))), uint256(ModuleState.LiquidityMigrator));
    }
    
    function testV3WithNoOpGovernance() public {
        console.log("\n=== V3 + NoOp Governance + V2 Migrator ===");
        
        // Use simple, safe tick values
        int24 tickLower = 46080;  // ~1.5x price
        int24 tickUpper = 92160;  // ~100x price  
        
        bytes memory tokenData = _encodeTokenData("Simple Token", "SIMPLE");
        bytes memory v3InitData = abi.encode(InitData({
            fee: 3000,
            tickLower: tickLower,
            tickUpper: tickUpper,
            numPositions: 1,  // Just one position for simplicity
            maxShareToBeSold: 1e17  // 10% max to be sold
        }));
        
        CreateParams memory params = CreateParams({
            initialSupply: 1_000_000 * 1e18,
            numTokensToSell: 10_000 * 1e18,  // Sell 1% of supply
            numeraire: WETH_BASE,
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenData,
            governanceFactory: noOpGovernanceFactory,
            governanceFactoryData: "",
            poolInitializer: v3Initializer,
            poolInitializerData: v3InitData,
            liquidityMigrator: v2Migrator,
            liquidityMigratorData: "",
            integrator: impersonatedAddress,
            salt: bytes32(uint256(1))
        });
        
        _deployToken(params);
    }
    
    function testV3WithFullGovernance() public {
        console.log("\n=== V3 + Full Governance + V2 Migrator ===");
        
        bytes memory tokenData = _encodeTokenData("Governed Token", "GOV");
        bytes memory governanceData = abi.encode(
            "Governed Token Governor",
            1,      // Minimal voting delay
            100,    // Short voting period for testing
            0       // No proposal threshold
        );
        bytes memory v3InitData = abi.encode(InitData({
            fee: 10000,  // 1% fee tier
            tickLower: 0,      
            tickUpper: 60000,  
            numPositions: 2,
            maxShareToBeSold: 2e17  // 20% max
        }));
        
        CreateParams memory params = CreateParams({
            initialSupply: 5_000_000 * 1e18,
            numTokensToSell: 50_000 * 1e18,  // Sell 1% of supply
            numeraire: WETH_BASE,
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenData,
            governanceFactory: governanceFactory,
            governanceFactoryData: governanceData,
            poolInitializer: v3Initializer,
            poolInitializerData: v3InitData,
            liquidityMigrator: v2Migrator,
            liquidityMigratorData: "",
            integrator: impersonatedAddress,
            salt: bytes32(uint256(2))
        });
        
        _deployToken(params);
    }
    
    function testV4WithNoOpGovernance() public {
        console.log("\n=== V4 + NoOp Governance + V2 Migrator ===");
        
        uint256 initialSupply = 10_000_000 * 1e18;
        uint256 numTokensToSell = 100_000 * 1e18;
        
        bytes memory tokenData = _encodeTokenData("V4 Token", "V4TK");
        
        // V4 configuration matching the expected format
        bytes memory v4InitData = abi.encode(
            0.01 ether,              // minimumProceeds
            10 ether,                // maximumProceeds
            block.timestamp,         // startingTime
            block.timestamp + 1 days,// endingTime
            int24(-200000),          // startingTick
            int24(200000),           // endingTick
            30 minutes,              // epochLength (N)
            int24(720),              // gamma
            false,                   // isToken0 (will be determined by mining)
            uint256(10),             // numPDSlugs (M - epochs)
            uint24(100),             // lpFee (1 basis point = 100)
            int24(1)                 // tickSpacing
        );
        
        // Mine for valid salt
        console.log("Mining for valid V4 addresses...");
        MineV4Params memory mineParams = MineV4Params({
            airlock: address(airlock),
            poolManager: _getV4PoolManager(),
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: WETH_BASE,
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenData,
            poolInitializer: v4Initializer,
            poolInitializerData: v4InitData
        });
        
        (bytes32 salt, address hook, address asset) = mineV4(mineParams);
        console.log("Found valid salt:", uint256(salt));
        console.log("Hook address:", hook);
        console.log("Asset address:", asset);
        
        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: WETH_BASE,
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenData,
            governanceFactory: noOpGovernanceFactory,
            governanceFactoryData: "",
            poolInitializer: v4Initializer,
            poolInitializerData: v4InitData,
            liquidityMigrator: v2Migrator,
            liquidityMigratorData: "",
            integrator: impersonatedAddress,
            salt: salt  // Use the mined salt
        });
        
        _deployToken(params);
    }
    
    function testV4WithFullGovernance() public {
        console.log("\n=== V4 + Full Governance + V2 Migrator ===");
        
        uint256 initialSupply = 10_000_000 * 1e18;
        uint256 numTokensToSell = 100_000 * 1e18;
        
        bytes memory tokenData = _encodeTokenData("V4 Gov Token", "V4GOV");
        bytes memory governanceData = abi.encode(
            "V4 Token Governor",
            7200,    // 1 day voting delay
            50400,   // 7 days voting period
            1000 * 1e18  // 1000 token proposal threshold
        );
        
        // V4 configuration
        bytes memory v4InitData = abi.encode(
            0.01 ether,              // minimumProceeds
            10 ether,                // maximumProceeds
            block.timestamp,         // startingTime
            block.timestamp + 1 days,// endingTime
            int24(-200000),          // startingTick
            int24(200000),           // endingTick
            30 minutes,              // epochLength (N)
            int24(720),              // gamma
            false,                   // isToken0 (will be determined by mining)
            uint256(10),             // numPDSlugs (M - epochs)
            uint24(100),             // lpFee (1 basis point = 100)
            int24(1)                 // tickSpacing
        );
        
        // Mine for valid salt
        console.log("Mining for valid V4 addresses...");
        MineV4Params memory mineParams = MineV4Params({
            airlock: address(airlock),
            poolManager: _getV4PoolManager(),
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: WETH_BASE,
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenData,
            poolInitializer: v4Initializer,
            poolInitializerData: v4InitData
        });
        
        (bytes32 salt, address hook, address asset) = mineV4(mineParams);
        console.log("Found valid salt:", uint256(salt));
        console.log("Hook address:", hook);
        console.log("Asset address:", asset);
        
        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: numTokensToSell,
            numeraire: WETH_BASE,
            tokenFactory: tokenFactory,
            tokenFactoryData: tokenData,
            governanceFactory: governanceFactory,
            governanceFactoryData: governanceData,
            poolInitializer: v4Initializer,
            poolInitializerData: v4InitData,
            liquidityMigrator: v2Migrator,
            liquidityMigratorData: "",
            integrator: impersonatedAddress,
            salt: salt  // Use the mined salt
        });
        
        _deployToken(params);
    }
}