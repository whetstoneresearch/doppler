// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency, CurrencyLibrary, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { LibClone } from "solady/utils/LibClone.sol";

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { UniswapV4MulticurveInitializer, InitData } from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { CloneERC20Factory } from "src/CloneERC20Factory.sol";
import { CloneERC20 } from "src/CloneERC20.sol";

contract CloneERC20FactoryIntegrationTest is Deployers {
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;
    UniswapV4MulticurveInitializer public initializer;
    UniswapV4MulticurveInitializerHook public multicurveHook;
    CloneERC20Factory public tokenFactory;
    GovernanceFactory public governanceFactory;
    NoOpMigrator public migrator;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(airlockOwner);
        tokenFactory = new CloneERC20Factory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        multicurveHook = UniswapV4MulticurveInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        initializer = new UniswapV4MulticurveInitializer(address(airlock), manager, multicurveHook);
        deployCodeTo("UniswapV4MulticurveInitializerHook", abi.encode(manager, initializer), address(multicurveHook));

        migrator = new NoOpMigrator(address(airlock));

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        vm.startPrank(airlockOwner);
        airlock.setModuleState(modules, states);
        vm.stopPrank();
    }

    function test_create(
        bytes32 salt
    ) public returns (address asset) {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

        bytes memory tokenData = abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "");

        address predictedAsset =
            LibClone.predictDeterministicAddress(tokenFactory.IMPLEMENTATION(), salt, address(tokenFactory));

        InitData memory initData = _prepareInitData(predictedAsset);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(0),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: tokenData,
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(migrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        vm.startSnapshotGas("CloneERC20FactoryIntegrationTest", "Multicurve+CloneERC20Factory");
        (asset,,,,) = airlock.create(params);
        vm.stopSnapshotGas("CloneERC20FactoryIntegrationTest", "Multicurve+CloneERC20Factory");
        require(asset == predictedAsset, "Asset address mismatch");
    }

    function test_gas() public {
        test_create(bytes32(type(uint256).max));
    }

    function test_migrate(
        bytes32 salt
    ) public {
        address asset = test_create(salt);

        bool isToken0 = false;

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: int256(1e27),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // numeraire.approve(address(swapRouter), type(uint256).max);
        deal(address(swapRouter), type(uint128).max);
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        vm.prank(airlockOwner);
        airlock.migrate(asset);
    }

    function _prepareInitData(
        address asset
    ) internal returns (InitData memory) {
        /*
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }
        */

        Curve[] memory curves = new Curve[](1);

        curves[0].tickLower = 0;
        curves[0].tickUpper = 240_000;
        curves[0].numPositions = 1;
        curves[0].shares = WAD;

        int24 tickSpacing = 8;

        Currency currency1 = Currency.wrap(asset);

        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            tickSpacing: tickSpacing,
            fee: 0,
            hooks: multicurveHook
        });
        poolId = poolKey.toId();

        return InitData({ fee: 0, tickSpacing: tickSpacing, curves: curves, beneficiaries: new BeneficiaryData[](0) });
    }
}
