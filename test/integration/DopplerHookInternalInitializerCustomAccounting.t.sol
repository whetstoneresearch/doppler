// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import {
    DopplerHookInternalInitializer,
    InitData
} from "src/initializers/DopplerHookInternalInitializer.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { IDopplerHook } from "src/interfaces/IDopplerHook.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DERC20 } from "src/tokens/DERC20.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract InternalInitializerLiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

contract ZeroDeltaDopplerHook is IDopplerHook {
    function onInitialization(address, PoolKey calldata, bytes calldata) external { }

    function onSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure returns (Currency, int128) {
        return (Currency.wrap(address(0)), 0);
    }

    function onGraduation(address, PoolKey calldata, bytes calldata) external { }
}

contract NonZeroDeltaDopplerHook is IDopplerHook {
    function onInitialization(address, PoolKey calldata, bytes calldata) external { }

    function onSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external pure returns (Currency, int128) {
        return (Currency.wrap(address(0)), 1);
    }

    function onGraduation(address, PoolKey calldata, bytes calldata) external { }
}

contract DopplerHookInternalInitializerCustomAccountingIntegrationTest is Deployers {
    address public airlockOwner = makeAddr("AirlockOwner");

    Airlock public airlock;
    DopplerHookInternalInitializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    InternalInitializerLiquidityMigratorMock public mockLiquidityMigrator;
    TestERC20 public numeraire;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        numeraire = new TestERC20(1e48);

        airlock = new Airlock(airlockOwner);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        initializer = DopplerHookInternalInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );
        deployCodeTo("DopplerHookInternalInitializer", abi.encode(address(airlock), address(manager)), address(initializer));

        mockLiquidityMigrator = new InternalInitializerLiquidityMigratorMock();

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

        vm.prank(airlockOwner);
        airlock.setModuleState(modules, states);
    }

    function test_swap_AllowsHookWhenDeltaIsZero() public {
        ZeroDeltaDopplerHook hook = new ZeroDeltaDopplerHook();
        _registerHook(address(hook), ON_SWAP_FLAG);

        (bool isToken0,) = _createToken(bytes32(uint256(101)), address(hook));
        _buyAsset(isToken0);
    }

    function test_swap_RevertsWhenHookReturnsCustomAccountingDelta() public {
        NonZeroDeltaDopplerHook hook = new NonZeroDeltaDopplerHook();
        _registerHook(address(hook), ON_SWAP_FLAG);

        (bool isToken0,) = _createToken(bytes32(uint256(102)), address(hook));

        vm.expectRevert();
        _buyAsset(isToken0);
    }

    function _registerHook(address hook, uint256 flags) internal {
        address[] memory hooks = new address[](1);
        hooks[0] = hook;

        uint256[] memory hookFlags = new uint256[](1);
        hookFlags[0] = flags;

        vm.prank(airlockOwner);
        initializer.setDopplerHookState(hooks, hookFlags);
    }

    function _buyAsset(bool isToken0) internal {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }

    function _prepareInitData(address token, address hook) internal returns (InitData memory) {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        Currency currency0 = Currency.wrap(address(numeraire));
        Currency currency1 = Currency.wrap(address(token));
        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        poolKey = PoolKey({ currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: initializer });
        poolId = poolKey.toId();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("beneficiary"), shares: uint96(0.95e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: uint96(0.05e18) });

        return InitData({
            fee: 10_000,
            tickSpacing: tickSpacing,
            farTick: 200_000,
            curves: curves,
            beneficiaries: beneficiaries,
            dopplerHook: hook,
            onInitializationDopplerHookCalldata: new bytes(0),
            graduationDopplerHookCalldata: new bytes(0)
        });
    }

    function _createToken(bytes32 salt, address hook) internal returns (bool isToken0, address asset) {
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
                        "TOKEN_URI"
                    )
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitData(tokenAddress, hook);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(numeraire),
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

        (asset,,,,) = airlock.create(params);
        isToken0 = asset < address(numeraire);

        (,,,,, poolKey,) = initializer.getState(asset);
        poolId = poolKey.toId();
        numeraire.approve(address(swapRouter), type(uint256).max);
    }
}
