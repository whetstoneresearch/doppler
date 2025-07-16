// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { UniswapV3Initializer, InitData } from "src/UniswapV3Initializer.sol";
import { UniswapV4Initializer } from "src/UniswapV4Initializer.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { 
    UNISWAP_V3_FACTORY_MAINNET, 
    UNISWAP_V4_POOL_MANAGER_MAINNET,
    UNISWAP_V3_FACTORY_BASE,
    UNISWAP_V4_POOL_MANAGER_BASE,
    UNISWAP_V2_FACTORY_MAINNET,
    UNISWAP_V2_ROUTER_MAINNET,
    UNISWAP_V2_FACTORY_BASE,
    UNISWAP_V2_ROUTER_BASE,
    UNISWAP_V3_FACTORY_BASE_SEPOLIA,
    UNISWAP_V4_POOL_MANAGER_BASE_SEPOLIA,
    WETH_BASE
} from "test/shared/Addresses.sol";

contract ForkTest is Test {
    uint256 public forkId;
    address public impersonatedAddress;
    Airlock public airlock;
    TokenFactory public tokenFactory;
    UniswapV3Initializer public v3Initializer;
    UniswapV4Initializer public v4Initializer;
    UniswapV2Migrator public v2Migrator;
    GovernanceFactory public governanceFactory;
    NoOpGovernanceFactory public noOpGovernanceFactory;
    
    function setUp() public virtual {
        _setupFork();
        _setupImpersonation();
        _deployAirlock();
        _deployAndWhitelistModules();
    }
    
    function _setupFork() internal {
        string memory rpcUrl = vm.envString("FORK_TEST_RPC_URL");
        forkId = vm.createSelectFork(rpcUrl);
        
        console.log("\n=== Fork Setup ===");
        console.log("Fork created with ID:", forkId);
        console.log("Fork block number:", block.number);
        console.log("Fork chain ID:", block.chainid);
        
        // Log which chain we're on
        if (block.chainid == 1) {
            console.log("Chain: Ethereum Mainnet");
        } else if (block.chainid == 8453) {
            console.log("Chain: Base Mainnet");
        } else if (block.chainid == 84532) {
            console.log("Chain: Base Sepolia");
        } else {
            console.log("Chain: Unknown");
        }
    }
    
    function _setupImpersonation() internal {
        impersonatedAddress = vm.envOr("FORK_TEST_IMPERSONATE_ADDRESS", address(0x1234567890123456789012345678901234567890));
        
        vm.startPrank(impersonatedAddress);
        vm.deal(impersonatedAddress, 1000 ether);
        
        console.log("\n=== Impersonation Setup ===");
        console.log("Impersonating address:", impersonatedAddress);
        console.log("ETH balance set to:", impersonatedAddress.balance / 1e18, "ETH");
    }
    
    function _deployAirlock() internal {
        console.log("\n=== Deploying Airlock ===");
        airlock = new Airlock(impersonatedAddress);
        
        console.log("Airlock deployed at:", address(airlock));
        console.log("Airlock owner:", airlock.owner());
    }

    function _deployAndWhitelistModules() internal {
        console.log("\n=== Deploying Modules ===");
        
        // Deploy TokenFactory
        tokenFactory = new TokenFactory(address(airlock));
        console.log("TokenFactory deployed at:", address(tokenFactory));
        
        // Deploy UniswapV3Initializer
        address v3Factory = _getV3Factory();
        if (v3Factory != address(0)) {
            console.log("Using Uniswap V3 Factory at:", v3Factory);
            try new UniswapV3Initializer(address(airlock), IUniswapV3Factory(v3Factory)) returns (UniswapV3Initializer v3Init) {
                v3Initializer = v3Init;
                console.log("UniswapV3Initializer deployed at:", address(v3Initializer));
            } catch {
                console.log("Failed to deploy UniswapV3Initializer");
            }
        } else {
            console.log("Skipping UniswapV3Initializer - no factory for chain", block.chainid);
        }
        
        // Deploy UniswapV4Initializer (requires DopplerDeployer)
        address poolManager = _getV4PoolManager();
        if (poolManager != address(0)) {
            console.log("Using Uniswap V4 PoolManager at:", poolManager);
            try new DopplerDeployer(IPoolManager(poolManager)) returns (DopplerDeployer deployer) {
                console.log("DopplerDeployer deployed at:", address(deployer));
                try new UniswapV4Initializer(address(airlock), IPoolManager(poolManager), deployer) returns (UniswapV4Initializer v4Init) {
                    v4Initializer = v4Init;
                    console.log("UniswapV4Initializer deployed at:", address(v4Initializer));
                } catch {
                    console.log("Failed to deploy UniswapV4Initializer");
                }
            } catch {
                console.log("Failed to deploy DopplerDeployer");
            }
        } else {
            console.log("Skipping UniswapV4Initializer - no pool manager for chain", block.chainid);
        }
        
        // Deploy GovernanceFactory
        governanceFactory = new GovernanceFactory(address(airlock));
        console.log("GovernanceFactory deployed at:", address(governanceFactory));
        
        // Deploy NoOpGovernanceFactory
        noOpGovernanceFactory = new NoOpGovernanceFactory();
        console.log("NoOpGovernanceFactory deployed at:", address(noOpGovernanceFactory));
        
        // Deploy migrator modules
        _deployMigrators();
        
        // Register all modules with Airlock
        _registerModules();
    }
    
    function _registerModules() internal {
        // Count how many modules we have
        uint256 moduleCount = 3; // tokenFactory, governanceFactory, and noOpGovernanceFactory are always deployed
        if (address(v3Initializer) != address(0)) moduleCount++;
        if (address(v4Initializer) != address(0)) moduleCount++;
        if (address(v2Migrator) != address(0)) moduleCount++;
        
        address[] memory modules = new address[](moduleCount);
        ModuleState[] memory states = new ModuleState[](moduleCount);
        
        uint256 idx = 0;
        
        // Add TokenFactory
        modules[idx] = address(tokenFactory);
        states[idx] = ModuleState.TokenFactory;
        idx++;
        
        // Add GovernanceFactory
        modules[idx] = address(governanceFactory);
        states[idx] = ModuleState.GovernanceFactory;
        idx++;
        
        // Add NoOpGovernanceFactory as a GovernanceFactory
        modules[idx] = address(noOpGovernanceFactory);
        states[idx] = ModuleState.GovernanceFactory;
        idx++;
        
        // Add V3 Initializer if deployed
        if (address(v3Initializer) != address(0)) {
            modules[idx] = address(v3Initializer);
            states[idx] = ModuleState.PoolInitializer;
            idx++;
        }
        
        // Add V4 Initializer if deployed
        if (address(v4Initializer) != address(0)) {
            modules[idx] = address(v4Initializer);
            states[idx] = ModuleState.PoolInitializer;
            idx++;
        }
        
        // Add V2 Migrator if deployed
        if (address(v2Migrator) != address(0)) {
            modules[idx] = address(v2Migrator);
            states[idx] = ModuleState.LiquidityMigrator;
            idx++;
        }
        
        // Register all modules at once
        airlock.setModuleState(modules, states);
        console.log("\n=== Module Registration Complete ===");
        console.log("Registered", moduleCount, "modules with Airlock");
    }

    function testAirlockDeployment() public {
        assertNotEq(address(airlock), address(0));
        assertEq(airlock.owner(), impersonatedAddress);
    }
    
    function testModuleDeployments() public {
        // Test all modules are deployed
        assertNotEq(address(tokenFactory), address(0));
        assertNotEq(address(governanceFactory), address(0));
        assertNotEq(address(noOpGovernanceFactory), address(0));
        
        // Test optional modules based on chain
        if (block.chainid == 1 || block.chainid == 8453 || block.chainid == 84532) {
            assertNotEq(address(v3Initializer), address(0), "V3 initializer should be deployed");
            assertNotEq(address(v4Initializer), address(0), "V4 initializer should be deployed");
            // V2 migrator only on mainnet and Base mainnet
            if (block.chainid == 1 || block.chainid == 8453) {
                assertNotEq(address(v2Migrator), address(0), "V2 migrator should be deployed");
            }
        }
        
        // Test module registration
        assertEq(uint256(airlock.getModuleState(address(tokenFactory))), uint256(ModuleState.TokenFactory));
        assertEq(uint256(airlock.getModuleState(address(governanceFactory))), uint256(ModuleState.GovernanceFactory));
        assertEq(uint256(airlock.getModuleState(address(noOpGovernanceFactory))), uint256(ModuleState.GovernanceFactory));
        
        // Test optional module registration
        if (address(v3Initializer) != address(0)) {
            assertEq(uint256(airlock.getModuleState(address(v3Initializer))), uint256(ModuleState.PoolInitializer));
        }
        if (address(v4Initializer) != address(0)) {
            assertEq(uint256(airlock.getModuleState(address(v4Initializer))), uint256(ModuleState.PoolInitializer));
        }
        if (address(v2Migrator) != address(0)) {
            assertEq(uint256(airlock.getModuleState(address(v2Migrator))), uint256(ModuleState.LiquidityMigrator));
        }
    }
    
    function _getV3Factory() internal view returns (address) {
        if (block.chainid == 1) return UNISWAP_V3_FACTORY_MAINNET;
        if (block.chainid == 8453) return UNISWAP_V3_FACTORY_BASE;
        if (block.chainid == 84532) return UNISWAP_V3_FACTORY_BASE_SEPOLIA;
        return address(0);
    }
    
    function _getV4PoolManager() internal view returns (address) {
        if (block.chainid == 1) return UNISWAP_V4_POOL_MANAGER_MAINNET;
        if (block.chainid == 8453) return UNISWAP_V4_POOL_MANAGER_BASE;
        if (block.chainid == 84532) return UNISWAP_V4_POOL_MANAGER_BASE_SEPOLIA;
        return address(0);
    }
    
    function _getV2Factory() internal view returns (address) {
        if (block.chainid == 1) return UNISWAP_V2_FACTORY_MAINNET;
        if (block.chainid == 8453) return UNISWAP_V2_FACTORY_BASE;
        return address(0);
    }
    
    function _getV2Router() internal view returns (address) {
        if (block.chainid == 1) return UNISWAP_V2_ROUTER_MAINNET;
        if (block.chainid == 8453) return UNISWAP_V2_ROUTER_BASE;
        return address(0);
    }
    
    function _deployMigrators() internal {
        console.log("\n=== Deploying Migrators ===");
        
        // Deploy V2 Migrator
        address v2Factory = _getV2Factory();
        address v2Router = _getV2Router();
        if (v2Factory != address(0) && v2Router != address(0)) {
            console.log("Using Uniswap V2 Factory at:", v2Factory);
            console.log("Using Uniswap V2 Router at:", v2Router);
            v2Migrator = new UniswapV2Migrator(
                address(airlock),
                IUniswapV2Factory(v2Factory),
                IUniswapV2Router02(v2Router),
                impersonatedAddress // owner for the locker
            );
            console.log("UniswapV2Migrator deployed at:", address(v2Migrator));
        } else {
            console.log("Skipping UniswapV2Migrator - no V2 contracts for chain", block.chainid);
        }
    }
    
    function tearDown() public virtual {
        vm.stopPrank();
    }
    
    // Token deployment test functions
    
    function testSimpleV3Deployment() public {
        console.log("\n=== Simple V3 Token Deployment Test ===");
        
        if (!_canRunTest()) {
            console.log("Skipping - required modules not available");
            return;
        }
        
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
    
    function testV3WithGovernance() public {
        console.log("\n=== V3 Token with Governance Test ===");
        
        if (!_canRunTest()) {
            console.log("Skipping - required modules not available");
            return;
        }
        
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
    
    function testV4Deployment() public {
        console.log("\n=== V4 Token Deployment Test ===");
        
        if (!_canRunTest() || address(v4Initializer) == address(0)) {
            console.log("Skipping - V4 initializer not available");
            return;
        }
        
        bytes memory tokenData = _encodeTokenData("V4 Token", "V4TK");
        
        // Simple V4 configuration
        bytes memory v4InitData = abi.encode(
            0.001 ether,             // minimumProceeds
            1 ether,                 // maximumProceeds
            block.timestamp,         // startingTime
            block.timestamp + 1 hours, // endingTime (short for testing)
            1000,                    // startTick
            50000,                   // endTick
            int16(100),              // fee (1 basis point = 100)
            int16(1),                // tickSpacing
            240,                     // gamma
            5,                       // M (epochs)
            10 minutes               // N (epoch length)
        );
        
        CreateParams memory params = CreateParams({
            initialSupply: 10_000_000 * 1e18,
            numTokensToSell: 100_000 * 1e18,  // Sell 1% of supply
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
            salt: bytes32(uint256(3))
        });
        
        _deployToken(params);
    }
    
    // Helper functions for token deployment tests
    
    function _canRunTest() internal view returns (bool) {
        return address(tokenFactory) != address(0) && 
               address(v3Initializer) != address(0) &&
               address(v2Migrator) != address(0) &&
               address(governanceFactory) != address(0) &&
               address(noOpGovernanceFactory) != address(0);
    }
    
    function _encodeTokenData(
        string memory name,
        string memory symbol
    ) internal pure returns (bytes memory) {
        address[] memory recipients = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        return abi.encode(
            name,
            symbol,
            0,           // yearlyMintCap
            0,           // vestingDuration
            recipients,
            amounts,
            ""           // tokenURI
        );
    }
    
    function _deployToken(CreateParams memory params) internal {
        (address asset, address pool, address governance, address timelock, address migrationPool) = 
            airlock.create(params);
        
        console.log("\nDeployment successful!");
        console.log("- Asset:", asset);
        console.log("- Pool:", pool);
        console.log("- Governance:", governance);
        console.log("- Timelock:", timelock);
        console.log("- Migration Pool:", migrationPool);
        
        // Basic verifications
        assertNotEq(asset, address(0), "Asset should be created");
        assertNotEq(pool, address(0), "Pool should be created");
        
        IERC20 token = IERC20(asset);
        assertEq(token.totalSupply(), params.initialSupply, "Total supply mismatch");
        
        console.log("\nToken details:");
        console.log("- Total Supply:", token.totalSupply() / 1e18);
        console.log("- Airlock Balance:", token.balanceOf(address(airlock)) / 1e18);
        
        console.log("\n[SUCCESS] Token deployment complete!\n");
    }
}
