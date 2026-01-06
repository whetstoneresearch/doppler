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
contract LiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

/// @title RehypeSetup
/// @notice Base setup contract for RehypeDopplerHook invariant tests
/// @dev Deploys full Airlock stack with RehypeDopplerHook
abstract contract RehypeSetup is Deployers {
    // ─────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────

    address public constant PROTOCOL_OWNER = address(0xB16B055);

    // ─────────────────────────────────────────────────────────────────────────────
    // Actors
    // ─────────────────────────────────────────────────────────────────────────────

    address public airlockOwner;
    address public buybackDst;
    address public beneficiary1;
    address public beneficiary2;

    // ─────────────────────────────────────────────────────────────────────────────
    // Core Contracts
    // ─────────────────────────────────────────────────────────────────────────────

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    LiquidityMigratorMock public mockLiquidityMigrator;
    RehypeDopplerHook public rehypeDopplerHook;

    // ─────────────────────────────────────────────────────────────────────────────
    // Tokens
    // ─────────────────────────────────────────────────────────────────────────────

    TestERC20 public numeraire;
    TestERC20 public asset;

    // ─────────────────────────────────────────────────────────────────────────────
    // Pool State
    // ─────────────────────────────────────────────────────────────────────────────

    PoolKey public poolKey;
    PoolId public poolId;
    bool public isToken0;
    bool public isUsingEth;

    // ─────────────────────────────────────────────────────────────────────────────
    // Fee Distribution Config (can be overridden before _createToken)
    // ─────────────────────────────────────────────────────────────────────────────

    uint256 public assetBuybackPercent = 0.2e18;
    uint256 public numeraireBuybackPercent = 0.2e18;
    uint256 public beneficiaryPercent = 0.3e18;
    uint256 public lpPercent = 0.3e18;
    uint24 public customFee = 3000; // 0.3%

    // ─────────────────────────────────────────────────────────────────────────────
    // Setup Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Set up the full Airlock stack with RehypeDopplerHook
    /// @param useEth Whether to use native ETH as numeraire
    function _setupRehype(bool useEth) internal {
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

        // Deploy RehypeDopplerHook
        rehypeDopplerHook = new RehypeDopplerHook(address(initializer), manager);
        vm.label(address(rehypeDopplerHook), "RehypeDopplerHook");

        // Deploy mock migrator
        mockLiquidityMigrator = new LiquidityMigratorMock();
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
    }

    /// @notice Create a token and initialize the pool
    /// @param salt Salt for CREATE2 deployment
    /// @return assetAddr The deployed asset address
    function _createToken(bytes32 salt) internal returns (address assetAddr) {
        string memory name = "Test Token";
        string memory symbol = "TEST";
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

        InitData memory initData = _prepareInitData(tokenAddress);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: isUsingEth ? address(0) : address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        (assetAddr,,,,) = airlock.create(params);
        asset = TestERC20(assetAddr);
        vm.label(assetAddr, "Asset");

        // Determine token ordering
        isToken0 = assetAddr < (isUsingEth ? address(0) : address(numeraire));

        // Get pool key and ID
        (,,,,, poolKey,) = initializer.getState(assetAddr);
        poolId = poolKey.toId();
    }

    /// @notice Prepare initialization data for the pool
    /// @param token The token address
    /// @return initData The initialization data
    function _prepareInitData(address token) internal returns (InitData memory initData) {
        // Create multicurve configuration
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        // Determine currency ordering
        Currency currency0 = Currency.wrap(isUsingEth ? address(0) : address(numeraire));
        Currency currency1 = Currency.wrap(token);

        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        // Set up pool key (used internally, will be overwritten by actual)
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            tickSpacing: tickSpacing,
            fee: 0,
            hooks: initializer
        });
        poolId = poolKey.toId();

        // Create beneficiaries (must be sorted ascending)
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: beneficiary1, shares: uint96(0.95e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: beneficiary2, shares: uint96(0.05e18) });

        // Prepare RehypeDopplerHook initialization data
        bytes memory rehypeData = abi.encode(
            isUsingEth ? address(0) : address(numeraire),
            buybackDst,
            customFee,
            assetBuybackPercent,
            numeraireBuybackPercent,
            beneficiaryPercent,
            lpPercent
        );

        initData = InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            farTick: 200_000,
            curves: curves,
            beneficiaries: beneficiaries,
            dopplerHook: address(rehypeDopplerHook),
            onInitializationDopplerHookCalldata: rehypeData,
            graduationDopplerHookCalldata: new bytes(0)
        });
    }

    /// @notice Set fee distribution percentages (call before _createToken)
    /// @param assetBuyback Percentage for asset buyback (WAD)
    /// @param numeraireBuyback Percentage for numeraire buyback (WAD)
    /// @param beneficiary Percentage for beneficiary (WAD)
    /// @param lp Percentage for LP reinvestment (WAD)
    function _setFeeDistribution(
        uint256 assetBuyback,
        uint256 numeraireBuyback,
        uint256 beneficiary,
        uint256 lp
    ) internal {
        require(assetBuyback + numeraireBuyback + beneficiary + lp == WAD, "Must sum to WAD");
        assetBuybackPercent = assetBuyback;
        numeraireBuybackPercent = numeraireBuyback;
        beneficiaryPercent = beneficiary;
        lpPercent = lp;
    }

    /// @notice Set custom fee (call before _createToken)
    /// @param fee Custom fee in parts per million
    function _setCustomFee(uint24 fee) internal {
        require(fee <= 1e6, "Fee too high");
        customFee = fee;
    }
}
