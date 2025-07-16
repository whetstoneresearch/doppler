// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
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
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
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

abstract contract BaseForkTest is Test {
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
            revert("Unsupported chain - only Ethereum Mainnet, Base Mainnet, and Base Sepolia are supported");
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
        
        // Get required addresses - fail if not available
        address v3Factory = _getV3Factory();
        address v4PoolManager = _getV4PoolManager();
        address v2Factory = _getV2Factory();
        address v2Router = _getV2Router();
        
        require(v3Factory != address(0), "V3 Factory not available for this chain");
        require(v4PoolManager != address(0), "V4 PoolManager not available for this chain");
        require(v2Factory != address(0), "V2 Factory not available for this chain");
        require(v2Router != address(0), "V2 Router not available for this chain");
        
        // Deploy TokenFactory
        tokenFactory = new TokenFactory(address(airlock));
        console.log("TokenFactory deployed at:", address(tokenFactory));
        
        // Deploy UniswapV3Initializer
        console.log("Using Uniswap V3 Factory at:", v3Factory);
        v3Initializer = new UniswapV3Initializer(address(airlock), IUniswapV3Factory(v3Factory));
        console.log("UniswapV3Initializer deployed at:", address(v3Initializer));
        
        // Deploy UniswapV4Initializer
        console.log("Using Uniswap V4 PoolManager at:", v4PoolManager);
        DopplerDeployer deployer = new DopplerDeployer(IPoolManager(v4PoolManager));
        console.log("DopplerDeployer deployed at:", address(deployer));
        v4Initializer = new UniswapV4Initializer(address(airlock), IPoolManager(v4PoolManager), deployer);
        console.log("UniswapV4Initializer deployed at:", address(v4Initializer));
        
        // Deploy GovernanceFactory
        governanceFactory = new GovernanceFactory(address(airlock));
        console.log("GovernanceFactory deployed at:", address(governanceFactory));
        
        // Deploy NoOpGovernanceFactory
        noOpGovernanceFactory = new NoOpGovernanceFactory();
        console.log("NoOpGovernanceFactory deployed at:", address(noOpGovernanceFactory));
        
        // Deploy V2 Migrator
        console.log("Using Uniswap V2 Factory at:", v2Factory);
        console.log("Using Uniswap V2 Router at:", v2Router);
        v2Migrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(v2Factory),
            IUniswapV2Router02(v2Router),
            impersonatedAddress // owner for the locker
        );
        console.log("UniswapV2Migrator deployed at:", address(v2Migrator));
        
        // Register all modules with Airlock
        _registerModules();
    }
    
    function _registerModules() internal {
        console.log("\n=== Registering Modules ===");
        
        // Register all modules - they're always deployed now
        _registerModule(address(tokenFactory), ModuleState.TokenFactory);
        _registerModule(address(governanceFactory), ModuleState.GovernanceFactory);
        _registerModule(address(noOpGovernanceFactory), ModuleState.GovernanceFactory);
        _registerModule(address(v3Initializer), ModuleState.PoolInitializer);
        _registerModule(address(v4Initializer), ModuleState.PoolInitializer);
        _registerModule(address(v2Migrator), ModuleState.LiquidityMigrator);
        
        console.log("Module registration complete");
    }
    
    function _registerModule(address module, ModuleState state) internal {
        address[] memory modules = new address[](1);
        ModuleState[] memory states = new ModuleState[](1);
        modules[0] = module;
        states[0] = state;
        airlock.setModuleState(modules, states);
        console.log("Registered", module, "as", uint256(state));
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
    
    function tearDown() public virtual {
        vm.stopPrank();
    }
    
    // Helper functions for token deployment
    
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