// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Vm } from "forge-std/Vm.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import { Airlock, ModuleState, CreateParams } from "src/Airlock.sol";
import { UniswapV4MulticurveInitializer, InitData } from "src/UniswapV4MulticurveInitializer.sol";
import { UniswapV4MulticurveInitializerHook } from "src/UniswapV4MulticurveInitializerHook.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV4MulticurveMigrator } from "src/UniswapV4MulticurveMigrator.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { DERC20 } from "src/DERC20.sol";

function deployUniswapV4MulticurveInitializer(
    Vm vm,
    Airlock airlock,
    address airlockOwner,
    address poolManager
) returns (UniswapV4MulticurveInitializerHook multicurveHook, UniswapV4MulticurveInitializer initializer) {
    multicurveHook = UniswapV4MulticurveInitializerHook(
        address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        )
    );
    initializer = new UniswapV4MulticurveInitializer(address(airlock), IPoolManager(poolManager), multicurveHook);
    address[] memory modules = new address[](1);
    modules[0] = address(initializer);
    ModuleState[] memory states = new ModuleState[](1);
    states[0] = ModuleState.PoolInitializer;
    vm.prank(airlockOwner);
    airlock.setModuleState(modules, states);
}

contract LiquidityMigratorMock is ILiquidityMigrator {
    receive() external payable { }

    function initialize(
        address,
        address,
        bytes memory
    ) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(
        uint160,
        address,
        address,
        address
    ) external payable override returns (uint256) {
        return 0;
    }
}

contract V4MulticurveInitializer is Deployers {
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;
    UniswapV4MulticurveInitializer public initializer;
    UniswapV4MulticurveInitializerHook public multicurveHook;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    LiquidityMigratorMock public migrator;
    address public numeraire;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(airlockOwner);
        tokenFactory = new TokenFactory(address(airlock));
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

        migrator = new LiquidityMigratorMock();

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

    uint256 initialSupply = 1e27;

    function testFuzz_create_MulticurveInitializerV4(
        bytes32 salt,
        bool isUsingEth
    ) public returns (address asset) {
        string memory name = "Test Token";
        string memory symbol = "TEST";

        numeraire = isUsingEth ? address(0) : address(new TestERC20(type(uint128).max));
        vm.label(address(numeraire), "Numeraire");

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
            numeraire: address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(migrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        vm.startSnapshotGas("V4MulticurveInitializer", "Multicurve+TokenFactory");
        (asset,,,,) = airlock.create(params);
        vm.stopSnapshotGas("V4MulticurveInitializer", "Multicurve+TokenFactory");
        require(asset == tokenAddress, "Unexpected token address");
    }

    function test_gas_MulticurveInitializerV4() public {
        testFuzz_create_MulticurveInitializerV4(bytes32(type(uint256).max), true);
    }

    function testFuzz_migrate_MulticurveInitializerV4(
        bytes32 salt,
        bool isUsingEth
    ) public {
        address asset = testFuzz_create_MulticurveInitializerV4(salt, isUsingEth);

        bool isToken0 = asset < address(numeraire);

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: int256(initialSupply),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        if (isUsingEth) {
            vm.deal(address(swapRouter), type(uint128).max);
        } else {
            TestERC20(numeraire).approve(address(swapRouter), type(uint128).max);
        }

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        vm.prank(airlockOwner);
        airlock.migrate(asset);
    }

    function _prepareInitData(
        address token
    ) internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        Currency currency0 = Currency.wrap(address(numeraire));
        Currency currency1 = Currency.wrap(address(token));

        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: multicurveHook
        });
        poolId = poolKey.toId();

        return InitData({ fee: 0, tickSpacing: tickSpacing, curves: curves, beneficiaries: new BeneficiaryData[](0) });
    }
}
