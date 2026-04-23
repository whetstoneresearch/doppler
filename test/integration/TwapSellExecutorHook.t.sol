pragma solidity ^0.8.13;

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
import { DopplerHookInitializer, InitData } from "src/initializers/DopplerHookInitializer.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DERC20 } from "src/tokens/DERC20.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

import { TwapSellExecutorHook, ITwapVault } from "src/dopplerHooks/TwapSellExecutorHook.sol";
import { TwapVault } from "src/twap/TwapVault.sol";

contract LiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

contract TwapSellExecutorHookIntegrationTest is Deployers {
    address public airlockOwner = makeAddr("AirlockOwner");
    address public buybackDst;

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    LiquidityMigratorMock public mockLiquidityMigrator;
    TestERC20 public numeraire;

    TwapVault public vault;
    TwapSellExecutorHook public twapHook;

    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        buybackDst = address(this);
        numeraire = new TestERC20(1e48);

        airlock = new Airlock(airlockOwner);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        initializer = DopplerHookInitializer(
            payable(address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x4444 << 144)
            ))
        );
        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));

        vault = new TwapVault(airlockOwner);
        twapHook = new TwapSellExecutorHook(address(initializer), manager, ITwapVault(address(vault)));

        vm.startPrank(airlockOwner);
        vault.setExecutor(address(twapHook));

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

        airlock.setModuleState(modules, states);

        address[] memory dopplerHooks = new address[](1);
        dopplerHooks[0] = address(twapHook);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;
        initializer.setDopplerHookState(dopplerHooks, flags);
        vm.stopPrank();
    }

    function test_twap_AccruesWhenNoInventory_ThenSellsAfterDeposit() public {
        bytes32 salt = bytes32(uint256(101));
        (bool isToken0, address asset) = _createToken(salt);

        // Warp forward so the schedule accrues budget.
        vm.warp(block.timestamp + 1 hours);

        // Swap once with zero vault inventory: should accrue accumulator but not sell.
        _swapNumeraireToAsset(isToken0, 1 ether);

        (uint256 acc1,) = twapHook.getTwapSellState(poolId);
        assertGt(acc1, 0, "accumulator should accrue even when inventory is zero");

        // Deposit inventory after accrual (use assets bought from the swap above).
        _depositAssetToVault(asset);

        // Next block: TWAP should sell some inventory and reduce accumulator.
        vm.roll(block.number + 1);

        uint256 invAssetBefore = vault.inventory(poolId, asset);
        uint256 invNumBefore = vault.inventory(poolId, address(numeraire));

        _swapNumeraireToAsset(isToken0, 0.5 ether);

        uint256 invAssetAfter = vault.inventory(poolId, asset);
        uint256 invNumAfter = vault.inventory(poolId, address(numeraire));

        assertLt(invAssetAfter, invAssetBefore, "asset inventory should decrease after TWAP sell");
        assertGt(invNumAfter, invNumBefore, "numeraire inventory should increase after TWAP sell");

        (uint256 acc2,) = twapHook.getTwapSellState(poolId);
        assertLt(acc2, acc1, "accumulator should be consumed by selling");
    }

    function test_twap_ExecutesAtMostOncePerBlock() public {
        bytes32 salt = bytes32(uint256(102));
        (bool isToken0, address asset) = _createToken(salt);

        // Accrue budget and acquire some asset to deposit.
        vm.warp(block.timestamp + 1 hours);
        _swapNumeraireToAsset(isToken0, 1 ether);
        vm.roll(block.number + 1);
        _depositAssetToVault(asset);

        // First swap triggers TWAP.
        _swapNumeraireToAsset(isToken0, 0.5 ether);
        uint256 invAfterFirst = vault.inventory(poolId, asset);

        // Second swap in the same block should not execute TWAP again.
        _swapNumeraireToAsset(isToken0, 0.5 ether);
        uint256 invAfterSecond = vault.inventory(poolId, asset);

        assertEq(invAfterSecond, invAfterFirst, "TWAP should not execute twice in the same block");
    }

    function test_fullFlow_UserBuyTriggersTwapSell() public {
        bytes32 salt = bytes32(uint256(103));
        (bool isToken0, address asset) = _createToken(salt);

        // Accrue budget.
        vm.warp(block.timestamp + 2 hours);

        // Acquire asset so vault can TWAP-sell.
        _swapNumeraireToAsset(isToken0, 2 ether);
        vm.roll(block.number + 1);
        _depositAssetToVault(asset);

        uint256 invAssetBefore = vault.inventory(poolId, asset);
        uint256 invNumBefore = vault.inventory(poolId, address(numeraire));

        // A user "buy" (numeraire -> asset) should trigger the hook,
        // and the hook should TWAP-sell vault inventory asset -> numeraire.
        vm.roll(block.number + 1);
        _swapNumeraireToAsset(isToken0, 0.25 ether);

        uint256 invAssetAfter = vault.inventory(poolId, asset);
        uint256 invNumAfter = vault.inventory(poolId, address(numeraire));

        assertLt(invAssetAfter, invAssetBefore, "TWAP sell should reduce asset inventory");
        assertGt(invNumAfter, invNumBefore, "TWAP sell should increase numeraire inventory");

        // TODO: Add an invariant-style test asserting `vault.inventory(poolId, token) <= token.balanceOf(address(vault))`
        // for both tokens after TWAP execution (accounting should never exceed actual balances).
    }

    function _swapNumeraireToAsset(bool isToken0, uint256 amountInNumeraire) internal {
        // numeraire -> asset == !isToken0
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(amountInNumeraire),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }

    function _depositAssetToVault(address asset) internal {
        uint256 bal = TestERC20(asset).balanceOf(buybackDst);
        assertGt(bal, 0, "need asset balance to deposit");

        uint256 amount = bal / 2;
        if (amount == 0) amount = bal;

        TestERC20(asset).approve(address(vault), amount);
        vault.deposit(poolId, asset, amount);
    }

    function _prepareInitData(address token) internal returns (InitData memory) {
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

        poolKey = PoolKey({ currency0: currency0, currency1: currency1, tickSpacing: tickSpacing, fee: 0, hooks: initializer });
        poolId = poolKey.toId();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x07), shares: uint96(0.95e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: uint96(0.05e18) });

        uint32 startTs = uint32(block.timestamp);
        uint32 endTs = startTs + 2 days;
        uint256 rateValuePerSec = 1e12;
        uint256 maxValuePerExecute = 0;
        uint256 maxAccumulatorValue = 1e24;

        bytes memory twapData = abi.encode(
            address(numeraire),
            buybackDst,
            startTs,
            endTs,
            rateValuePerSec,
            maxValuePerExecute,
            maxAccumulatorValue
        );

        return InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            farTick: 200_000,
            curves: curves,
            beneficiaries: beneficiaries,
            dopplerHook: address(twapHook),
            onInitializationDopplerHookCalldata: twapData,
            graduationDopplerHookCalldata: new bytes(0)
        });
    }

    function _createToken(bytes32 salt) internal returns (bool isToken0, address asset) {
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
        isToken0 = asset < address(numeraire);

        (,,,,, poolKey,) = initializer.getState(asset);
        poolId = poolKey.toId();

        numeraire.approve(address(swapRouter), type(uint256).max);
        TestERC20(asset).approve(address(swapRouter), type(uint256).max);
    }
}
