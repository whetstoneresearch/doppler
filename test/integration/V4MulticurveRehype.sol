// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

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
import { UniswapV4MulticurveRehypeInitializer, InitData } from "src/UniswapV4MulticurveRehypeInitializer.sol";
import {
    IRehypeHook,
    UniswapV4MulticurveRehypeInitializerHook
} from "src/UniswapV4MulticurveRehypeInitializerHook.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { DERC20 } from "src/DERC20.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { FeeDistributionInfo } from "src/UniswapV4MulticurveRehypeInitializerHook.sol";
import { console } from "forge-std/console.sol";

contract LiquidityMigratorMock is ILiquidityMigrator {
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

contract V4MulticurveRehype is Deployers {
    address public airlockOwner = makeAddr("AirlockOwner");
    Airlock public airlock;
    UniswapV4MulticurveRehypeInitializer public initializer;
    UniswapV4MulticurveRehypeInitializerHook public multicurveHook;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    StreamableFeesLockerV2 public locker;
    LiquidityMigratorMock public mockLiquidityMigrator;
    TestERC20 public numeraire;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        numeraire = new TestERC20(1e48);
        vm.label(address(numeraire), "Numeraire");

        airlock = new Airlock(airlockOwner);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        multicurveHook = UniswapV4MulticurveRehypeInitializerHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        initializer = new UniswapV4MulticurveRehypeInitializer(address(airlock), manager, multicurveHook);
        locker = new StreamableFeesLockerV2(manager, airlockOwner);
        vm.label(address(multicurveHook), "Rehype Hook");
        deployCodeTo(
            "UniswapV4MulticurveRehypeInitializerHook", abi.encode(manager, initializer), address(multicurveHook)
        );

        mockLiquidityMigrator = new LiquidityMigratorMock();

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
        vm.stopPrank();
    }

    function test_create_MulticurveInitializerRehypeV4(
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
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        airlock.create(params);
    }

    function test_rehype_MulticurveInitializerRehypeV4_quote_for_asset_only(
        bytes32 salt
    ) public {
        (bool isToken0,) = _createToken(salt);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }

    function test_rehype_MulticurveInitializerRehypeV4_increases_beneficiary_fees(
        bytes32 salt
    ) public {
        (bool isToken0,) = _createToken(salt);
        IPoolManager.SwapParams memory swapParamsQuoteIn = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta initialSwapDeltas =
            swapRouter.swap(poolKey, swapParamsQuoteIn, PoolSwapTest.TestSettings(false, false), new bytes(0));
        IPoolManager.SwapParams memory swapParamsQuoteOut = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: -int256(isToken0 ? initialSwapDeltas.amount1() / 2 : initialSwapDeltas.amount0() / 2),
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParamsQuoteOut, PoolSwapTest.TestSettings(false, false), new bytes(0));

        (,,, uint128 beneficiaryFees0, uint128 beneficiaryFees1) = multicurveHook.getHookFees(poolId);
        assertGt(beneficiaryFees0, 0, "Beneficiary fees not increased");
        assertGt(beneficiaryFees1, 0, "Beneficiary fees not increased");
    }

    function test_rehype_MulticurveRehypeInitializerHook_collect_fees(
        bytes32 salt
    ) public {
        (bool isToken0,) = _createToken(salt);

        IPoolManager.SwapParams memory swapParamsQuoteIn = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta initialSwapDeltas =
            swapRouter.swap(poolKey, swapParamsQuoteIn, PoolSwapTest.TestSettings(false, false), new bytes(0));

        uint256 hookBalance0 = TestERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(multicurveHook));
        uint256 hookBalance1 = TestERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(multicurveHook));
        IPoolManager.SwapParams memory swapParamsQuoteOut = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: -int256(isToken0 ? initialSwapDeltas.amount1() / 2 : initialSwapDeltas.amount0() / 2),
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParamsQuoteOut, PoolSwapTest.TestSettings(false, false), new bytes(0));

        hookBalance0 = TestERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(multicurveHook));
        hookBalance1 = TestERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(multicurveHook));

        (uint128 fees0, uint128 fees1) = initializer.collectFees(poolId);
        assertGt(fees0, 0, "Fees not collected");
        assertGt(fees1, 0, "Fees not collected");

        hookBalance0 = TestERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(multicurveHook));
        hookBalance1 = TestERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(multicurveHook));

        assertEq(hookBalance0, 0, "Hook balance does not net out on token0");
        assertEq(hookBalance1, 0, "Hook balance does not net out on token1");
    }

    function test_rehype_MulticurveRehypeInitializerHook_mixed_swap_types(
        bytes32 salt
    ) public {
        (bool isToken0,) = _createToken(salt);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta1 =
            swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        BalanceDelta delta2 =
            swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        BalanceDelta delta3 =
            swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
        BalanceDelta delta4 =
            swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));

        BalanceDelta deltas = BalanceDeltaLibrary.ZERO_DELTA;

        deltas = deltas + delta1;
        deltas = deltas + delta2;
        deltas = deltas + delta3;
        deltas = deltas + delta4;

        IPoolManager.SwapParams memory swapParams2 = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: isToken0 ? deltas.amount0() * 9 / 10 : deltas.amount1() * 9 / 10,
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(poolKey, swapParams2, PoolSwapTest.TestSettings(false, false), new bytes(0));
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

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x07), shares: uint96(0.95e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: uint96(0.05e18) });

        return InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            curves: curves,
            beneficiaries: beneficiaries,
            customFee: 3000,
            buybackDst: address(0x07),
            assetBuybackPercentWad: 0.2e18,
            numeraireBuybackPercentWad: 0.2e18,
            beneficiaryPercentWad: 0.3e18,
            lpPercentWad: 0.3e18
        });
    }

    function _createToken(
        bytes32 salt
    ) internal returns (bool isToken0, address asset) {
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

        InitData memory initData = _prepareInitData(tokenAddress);

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
        vm.label(asset, "Asset");
        isToken0 = asset < address(numeraire);
        numeraire.approve(address(swapRouter), type(uint256).max);
        TestERC20(asset).approve(address(swapRouter), type(uint256).max);
    }
}
