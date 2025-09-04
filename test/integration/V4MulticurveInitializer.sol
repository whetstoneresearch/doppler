// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";

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

contract LiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

contract V4MulticurveInitializer is Deployers {
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;
    UniswapV4MulticurveInitializer public initializer;
    UniswapV4MulticurveInitializerHook public multicurveHook;
    UniswapV4MigratorHook public migratorHook;
    UniswapV4MulticurveMigrator public migrator;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    StreamableFeesLockerV2 public locker;
    LiquidityMigratorMock public mockLiquidityMigrator;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");

        airlock = new Airlock(airlockOwner);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        multicurveHook = UniswapV4MulticurveInitializerHook(
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144))
        );
        initializer = new UniswapV4MulticurveInitializer(address(airlock), manager, multicurveHook);
        migratorHook = UniswapV4MigratorHook(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG) ^ (0x4444 << 144)));
        locker = new StreamableFeesLockerV2(manager, airlockOwner);
        migrator = new UniswapV4MulticurveMigrator(address(airlock), manager, migratorHook, locker);
        deployCodeTo("UniswapV4MigratorHook", abi.encode(manager, migrator), address(migratorHook));
        deployCodeTo("UniswapV4MulticurveInitializerHook", abi.encode(manager, initializer), address(multicurveHook));

        mockLiquidityMigrator = new LiquidityMigratorMock();

        address[] memory modules = new address[](5);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(migrator);
        modules[4] = address(mockLiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](5);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        states[4] = ModuleState.LiquidityMigrator;

        vm.startPrank(airlockOwner);
        airlock.setModuleState(modules, states);
        locker.approveMigrator(address(migrator));
        vm.stopPrank();
    }

    function test_create_MulticurveInitializerV4(
        bytes32 salt
    ) public {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

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
                        ""
                    )
                )
            ),
            address(tokenFactory)
        );

        // bool isToken0 = tokenAddress < address(0);

        InitData memory initData = _prepareInitData();

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: Currency.unwrap(currency1),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        airlock.create(params);
    }

    function _prepareInitData() internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            tickSpacing: tickSpacing,
            fee: 0,
            hooks: multicurveHook
        });
        poolId = poolKey.toId();

        return InitData({ fee: 0, tickSpacing: tickSpacing, curves: curves, beneficiaries: new BeneficiaryData[](0) });
    }
}
