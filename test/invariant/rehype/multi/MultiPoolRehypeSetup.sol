// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { DopplerHookInitializer, InitData } from "src/initializers/DopplerHookInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DERC20 } from "src/tokens/DERC20.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

/// @notice Mock liquidity migrator for testing
contract MultiPoolLiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

/// @notice Configuration for a single pool
struct PoolConfig {
    int24 tickSpacing;
    uint24 customFee;
    uint256 assetBuybackPercent;
    uint256 numeraireBuybackPercent;
    uint256 beneficiaryPercent;
    uint256 lpPercent;
}

/// @title MultiPoolRehypeSetup
/// @notice Base setup for multi-pool RehypeDopplerHook invariant tests
/// @dev Deploys a single hook instance managing multiple pools with different configurations
abstract contract MultiPoolRehypeSetup is Deployers {
    // ─────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────

    address public constant PROTOCOL_OWNER = address(0xB16B055);
    uint256 public constant NUM_POOLS = 3;

    // ─────────────────────────────────────────────────────────────────────────────
    // Actors
    // ─────────────────────────────────────────────────────────────────────────────

    address public airlockOwner;
    address public buybackDst;
    address public beneficiary1;
    address public beneficiary2;

    // ─────────────────────────────────────────────────────────────────────────────
    // Core Contracts (shared across all pools)
    // ─────────────────────────────────────────────────────────────────────────────

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    MultiPoolLiquidityMigratorMock public mockLiquidityMigrator;
    RehypeDopplerHook public rehypeDopplerHook;

    // ─────────────────────────────────────────────────────────────────────────────
    // Shared Numeraire
    // ─────────────────────────────────────────────────────────────────────────────

    TestERC20 public numeraire;
    bool public isUsingEth;

    // ─────────────────────────────────────────────────────────────────────────────
    // Per-Pool State (arrays)
    // ─────────────────────────────────────────────────────────────────────────────

    PoolKey[] internal _poolKeys;
    PoolId[] internal _poolIds;
    TestERC20[] internal _assets;
    bool[] internal _isToken0;
    PoolConfig[] internal _poolConfigs;

    // ─────────────────────────────────────────────────────────────────────────────
    // Accessors for inherited Deployers state
    // ─────────────────────────────────────────────────────────────────────────────

    function getManager() public view returns (IPoolManager) {
        return manager;
    }

    function getSwapRouter() public view returns (PoolSwapTest) {
        return swapRouter;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Accessors for Pool State
    // ─────────────────────────────────────────────────────────────────────────────

    function getPoolKey(uint256 index) public view returns (PoolKey memory) {
        require(index < _poolKeys.length, "Index out of bounds");
        return _poolKeys[index];
    }

    function getPoolId(uint256 index) public view returns (PoolId) {
        require(index < _poolIds.length, "Index out of bounds");
        return _poolIds[index];
    }

    function getAsset(uint256 index) public view returns (TestERC20) {
        require(index < _assets.length, "Index out of bounds");
        return _assets[index];
    }

    function getIsToken0(uint256 index) public view returns (bool) {
        require(index < _isToken0.length, "Index out of bounds");
        return _isToken0[index];
    }

    function getPoolConfig(uint256 index) public view returns (PoolConfig memory) {
        require(index < _poolConfigs.length, "Index out of bounds");
        return _poolConfigs[index];
    }

    function getPoolCount() public view returns (uint256) {
        return _poolKeys.length;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Setup Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Set up the full infrastructure and create multiple pools
    /// @param useEth Whether to use native ETH as numeraire
    function _setupMultiPoolRehype(bool useEth) internal {
        isUsingEth = useEth;

        // Create actor addresses
        airlockOwner = makeAddr("AirlockOwner");
        buybackDst = makeAddr("BuybackDst");
        beneficiary1 = address(0x07); // Must be low address for sorted beneficiaries
        beneficiary2 = airlockOwner;

        // Deploy V4 infrastructure
        deployFreshManagerAndRouters();

        // Deploy numeraire (skip for ETH)
        if (!useEth) {
            numeraire = new TestERC20(type(uint256).max);
            vm.label(address(numeraire), "Numeraire");
        }

        // Deploy Airlock
        airlock = new Airlock(airlockOwner);
        vm.label(address(airlock), "Airlock");

        // Deploy factories
        tokenFactory = new TokenFactory(address(airlock));
        vm.label(address(tokenFactory), "TokenFactory");

        governanceFactory = new GovernanceFactory(address(airlock));
        vm.label(address(governanceFactory), "GovernanceFactory");

        // Deploy initializer at deterministic address with hook flags
        initializer = DopplerHookInitializer(
            payable(
                address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                )
            )
        );

        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));
        vm.label(address(initializer), "DopplerHookInitializer");

        // Deploy RehypeDopplerHook (single instance for all pools)
        rehypeDopplerHook = new RehypeDopplerHook(address(initializer), manager);
        vm.label(address(rehypeDopplerHook), "RehypeDopplerHook");

        // Deploy mock migrator
        mockLiquidityMigrator = new MultiPoolLiquidityMigratorMock();
        vm.label(address(mockLiquidityMigrator), "LiquidityMigratorMock");

        // Set module states
        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(mockLiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        vm.startPrank(airlockOwner);
        airlock.setModuleState(modules, states);

        // Enable RehypeDopplerHook
        address[] memory dopplerHooks = new address[](1);
        dopplerHooks[0] = address(rehypeDopplerHook);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;
        initializer.setDopplerHookState(dopplerHooks, flags);
        vm.stopPrank();

        // Initialize pool configurations
        _initializePoolConfigs();

        // Create each pool
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            _createPoolWithConfig(i, bytes32(uint256(100 + i)));
        }
    }

    /// @notice Initialize pool configurations - override for custom configs
    function _initializePoolConfigs() internal virtual {
        // Pool 0: Conservative - low fee, wide tick spacing
        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 60,
                customFee: 1000, // 0.1%
                assetBuybackPercent: 0.2e18,
                numeraireBuybackPercent: 0.2e18,
                beneficiaryPercent: 0.3e18,
                lpPercent: 0.3e18
            })
        );

        // Pool 1: Aggressive LP - high fee, narrow tick spacing, 100% LP
        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 8,
                customFee: 10000, // 1%
                assetBuybackPercent: 0,
                numeraireBuybackPercent: 0,
                beneficiaryPercent: 0,
                lpPercent: WAD // 100%
            })
        );

        // Pool 2: High Beneficiary - wide tick spacing, 100% beneficiary
        _poolConfigs.push(
            PoolConfig({
                tickSpacing: 200,
                customFee: 3000, // 0.3%
                assetBuybackPercent: 0,
                numeraireBuybackPercent: 0,
                beneficiaryPercent: WAD, // 100%
                lpPercent: 0
            })
        );
    }

    /// @notice Create a pool with specific configuration
    /// @param configIndex Index into _poolConfigs
    /// @param salt Salt for CREATE2 deployment
    function _createPoolWithConfig(uint256 configIndex, bytes32 salt) internal {
        PoolConfig memory config = _poolConfigs[configIndex];

        string memory name = string(abi.encodePacked("Test Token ", vm.toString(configIndex)));
        string memory symbol = string(abi.encodePacked("TEST", vm.toString(configIndex)));
        uint256 initialSupply = 1e27;

        // Compute token address for InitData preparation
        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name,
                        symbol,
                        initialSupply,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        "TOKEN_URI"
                    )
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitDataForConfig(tokenAddress, config);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: isUsingEth ? address(0) : address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode(name, 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        (address assetAddr,,,,) = airlock.create(params);

        TestERC20 asset = TestERC20(assetAddr);
        vm.label(assetAddr, string(abi.encodePacked("Asset", vm.toString(configIndex))));

        // Determine token ordering
        bool isToken0 = assetAddr < (isUsingEth ? address(0) : address(numeraire));

        // Get pool key and ID
        (,,,,, PoolKey memory poolKey,) = initializer.getState(assetAddr);
        PoolId poolId = poolKey.toId();

        // Store pool data
        _assets.push(asset);
        _poolKeys.push(poolKey);
        _poolIds.push(poolId);
        _isToken0.push(isToken0);
    }

    /// @notice Prepare initialization data for a specific pool configuration
    function _prepareInitDataForConfig(
        address token,
        PoolConfig memory config
    ) internal view returns (InitData memory initData) {
        // Create multicurve configuration with the pool's tick spacing
        Curve[] memory curves = new Curve[](10);

        // Calculate tick step aligned with tickSpacing
        // Target step ~16000, but must be divisible by tickSpacing
        int24 tickSpacing = config.tickSpacing;
        int24 tickStep = (int24(16000) / tickSpacing) * tickSpacing;
        if (tickStep == 0) tickStep = tickSpacing * 100; // Fallback for very large spacings

        // Align upper tick to tickSpacing
        int24 upperTick = (int24(240000) / tickSpacing) * tickSpacing;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(int256(i)) * tickStep;
            curves[i].tickUpper = upperTick;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        // Determine currency ordering
        Currency currency0 = Currency.wrap(isUsingEth ? address(0) : address(numeraire));
        Currency currency1 = Currency.wrap(token);

        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        // Create beneficiaries (must be sorted ascending)
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: beneficiary1, shares: uint96(0.95e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: beneficiary2, shares: uint96(0.05e18) });

        // Prepare RehypeDopplerHook initialization data with pool-specific config
        bytes memory rehypeData = abi.encode(
            isUsingEth ? address(0) : address(numeraire),
            buybackDst,
            config.customFee,
            config.assetBuybackPercent,
            config.numeraireBuybackPercent,
            config.beneficiaryPercent,
            config.lpPercent
        );

        // Align farTick to tickSpacing
        int24 farTick = (int24(200000) / tickSpacing) * tickSpacing;

        initData = InitData({
            fee: 0,
            tickSpacing: config.tickSpacing,
            farTick: farTick,
            curves: curves,
            beneficiaries: beneficiaries,
            dopplerHook: address(rehypeDopplerHook),
            onInitializationDopplerHookCalldata: rehypeData,
            graduationDopplerHookCalldata: new bytes(0)
        });
    }
}
