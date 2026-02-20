// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Constants } from "@v4-core-test/utils/Constants.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, equals } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IV4Quoter, V4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { Test } from "forge-std/Test.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { ON_AFTER_SWAP_FLAG, ON_INITIALIZATION_FLAG } from "src/base/BaseDopplerHookMigrator.sol";
import { EPSILON, RehypeDopplerHookMigrator } from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";
import { AddressSet, LibAddressSet } from "test/invariant/AddressSet.sol";

uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
address constant AIRLOCK_OWNER = 0xf00000000000000000000000000000000000B055;

contract RehypeMigratorInvariantTests is Deployers {
    DopplerHookMigrator public migrator;
    RehypeDopplerHookMigrator public rehypeHook;
    StreamableFeesLockerV2 public locker;
    RehypeMigratorHandler public handler;
    V4Quoter public quoter;

    function setUp() public {
        deployFreshManager();
        swapRouter = new PoolSwapTest(manager);
        quoter = new V4Quoter(manager);

        handler = new RehypeMigratorHandler(manager, swapRouter, quoter);

        uint160 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        locker = new StreamableFeesLockerV2(manager, AIRLOCK_OWNER);
        address migratorAddress = address(uint160(hookFlags) ^ (0x4444 << 144));
        migrator = DopplerHookMigrator(payable(migratorAddress));
        deployCodeTo(
            "DopplerHookMigrator", abi.encode(address(handler), address(manager), locker, address(0)), migratorAddress
        );

        rehypeHook = new RehypeDopplerHookMigrator(migrator, manager);

        vm.prank(AIRLOCK_OWNER);
        locker.approveMigrator(address(migrator));

        address[] memory hooks = new address[](1);
        hooks[0] = address(rehypeHook);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_AFTER_SWAP_FLAG;
        vm.prank(AIRLOCK_OWNER);
        migrator.setDopplerHookState(hooks, flags);

        handler.setMigrator(migrator, rehypeHook, locker);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.initialize.selector;
        selectors[1] = handler.buyExactIn.selector;
        selectors[2] = handler.buyExactOut.selector;
        selectors[3] = handler.sellExactIn.selector;
        selectors[4] = handler.sellExactOut.selector;
        selectors[5] = handler.setFeeDistribution.selector;
        selectors[6] = handler.collectFees.selector;
        selectors[7] = handler.claimAirlockOwnerFees.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_HookIsAlwaysSolvent() public view {
        uint256 poolKeysLength = handler.poolKeysLength();

        for (uint256 i; i < poolKeysLength; i++) {
            PoolKey memory poolKey = handler.getPoolKey(i);
            PoolId poolId = poolKey.toId();

            (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeHook.getHookFees(poolId);
            assertGe(poolKey.currency0.balanceOf(address(rehypeHook)), beneficiaryFees0, "Insolvent for currency0");
            assertGe(poolKey.currency1.balanceOf(address(rehypeHook)), beneficiaryFees1, "Insolvent for currency1");
        }
    }

    function invariant_NoFeesAboveEpsilon() public view {
        uint256 poolKeysLength = handler.poolKeysLength();

        for (uint256 i; i < poolKeysLength; i++) {
            PoolKey memory poolKey = handler.getPoolKey(i);
            PoolId poolId = poolKey.toId();

            (uint128 fees0, uint128 fees1,,,,,) = rehypeHook.getHookFees(poolId);
            assertGe(EPSILON, fees0, "Excessive fees0 accumulated");
            assertGe(EPSILON, fees1, "Excessive fees1 accumulated");
        }
    }

    function invariant_FullRangeLiquidityNeverDecreases() public view {
        uint256 poolKeysLength = handler.poolKeysLength();

        for (uint256 i; i < poolKeysLength; i++) {
            PoolKey memory poolKey = handler.getPoolKey(i);
            PoolId poolId = poolKey.toId();

            uint256 ghostLiquidity = handler.ghost_liquidityOf(poolId);
            (,, uint256 currentLiquidity,) = rehypeHook.getPosition(poolId);
            assertGe(currentLiquidity, ghostLiquidity, "Full range liquidity decreased");
        }
    }
}

struct Settings {
    address asset;
    address numeraire;
    address buybackDst;
    uint24 customFee;
    uint256 assetBuybackPercentWad;
    uint256 numeraireBuybackPercentWad;
    uint256 beneficiaryPercentWad;
    uint256 lpPercentWad;
    bool isToken0;
}

contract RehypeMigratorHandler is Test {
    using LibAddressSet for AddressSet;

    IPoolManager public manager;
    DopplerHookMigrator public migrator;
    RehypeDopplerHookMigrator public rehypeHook;
    StreamableFeesLockerV2 public locker;
    PoolSwapTest public swapRouter;
    V4Quoter public quoter;

    mapping(PoolId => Settings) public settingsOf;
    PoolKey[] public poolKeys;
    uint256 public poolKeysLength;
    address[] public availableNumeraires;

    mapping(PoolId => uint256) public ghost_liquidityOf;

    AddressSet internal actors;
    address internal currentActor;

    modifier createActor() {
        currentActor = address(uint160(msg.sender) | uint160(0xfFfFFFFfFF000000000000000000000000000000));
        actors.add(currentActor);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors.rand(actorIndexSeed);
        if (currentActor == address(0)) {
            currentActor = address(uint160(msg.sender) | uint160(0xfFfFFFFfFF000000000000000000000000000000));
            actors.add(currentActor);
        }
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(IPoolManager manager_, PoolSwapTest swapRouter_, V4Quoter quoter_) {
        manager = manager_;
        swapRouter = swapRouter_;
        quoter = quoter_;

        availableNumeraires.push(address(0));
        for (uint256 i; i < 2; i++) {
            availableNumeraires.push(address(new TestERC20(0)));
        }
    }

    function setMigrator(
        DopplerHookMigrator migrator_,
        RehypeDopplerHookMigrator rehypeHook_,
        StreamableFeesLockerV2 locker_
    ) external {
        migrator = migrator_;
        rehypeHook = rehypeHook_;
        locker = locker_;
    }

    function owner() external pure returns (address) {
        return AIRLOCK_OWNER;
    }

    /* ------------------------------------------------------------------------------ */
    /*                                Target functions                                */
    /* ------------------------------------------------------------------------------ */

    function initialize(uint256 seed) public {
        vm.assume(seed % 100 > 5);

        address numeraire = availableNumeraires[seed % availableNumeraires.length];
        address asset = address(new TestERC20(1e27));

        bool isToken0 = asset < numeraire;
        address token0 = isToken0 ? asset : numeraire;
        address token1 = isToken0 ? numeraire : asset;

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xbeef), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });

        Settings memory settings = _randomizeSettings(seed, asset, numeraire);
        bytes memory onInitCalldata = abi.encode(
            settings.numeraire,
            settings.buybackDst,
            settings.customFee,
            settings.assetBuybackPercentWad,
            settings.numeraireBuybackPercentWad,
            settings.beneficiaryPercentWad,
            settings.lpPercentWad
        );

        bytes memory migratorData = abi.encode(
            uint24(3000),
            true,
            int24(8),
            uint32(30 days),
            beneficiaries,
            address(rehypeHook),
            onInitCalldata,
            address(0),
            uint256(0)
        );

        migrator.initialize(asset, numeraire, migratorData);

        if (token0 == address(0)) {
            deal(address(migrator), 50 ether);
        } else {
            deal(token0, address(this), 50 ether);
            TestERC20(token0).transfer(address(migrator), 50 ether);
        }

        if (token1 == address(0)) {
            deal(address(migrator), 50 ether);
        } else {
            deal(token1, address(this), 50 ether);
            TestERC20(token1).transfer(address(migrator), 50 ether);
        }

        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, address(0xbeef));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(token0, token1);
        poolKeys.push(poolKey);
        poolKeysLength++;

        settings.isToken0 = equals(poolKey.currency0, Currency.wrap(asset));
        settingsOf[poolKey.toId()] = settings;
    }

    function buyExactIn(uint256 amount) public createActor {
        if (poolKeys.length == 0) return;

        amount = 1e18;
        PoolKey memory poolKey = poolKeys[amount % poolKeys.length];
        PoolId poolId = poolKey.toId();
        Settings memory settings = settingsOf[poolId];

        if (settings.numeraire == address(0)) {
            deal(currentActor, amount);
        } else {
            deal(settings.numeraire, currentActor, amount);
            TestERC20(settings.numeraire).approve(address(swapRouter), amount);
        }

        try swapRouter.swap{ value: settings.numeraire == address(0) ? amount : 0 }(
            poolKey,
            IPoolManager.SwapParams(
                !settings.isToken0, -int256(amount), settings.isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta
        ) { }
        catch {
            revert("buyExactIn failed");
        }

        _trackLiquidity(poolId);
    }

    function buyExactOut(uint256 amountOut) public createActor {
        if (poolKeys.length == 0) return;

        amountOut = 1e18;
        PoolKey memory poolKey = poolKeys[amountOut % poolKeys.length];
        PoolId poolId = poolKey.toId();
        Settings memory settings = settingsOf[poolId];

        (uint256 amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: !settings.isToken0,
                exactAmount: uint128(amountOut),
                hookData: new bytes(0)
            })
        );

        if (settings.numeraire == address(0)) {
            deal(currentActor, amountIn);
        } else {
            deal(settings.numeraire, currentActor, amountIn);
            TestERC20(settings.numeraire).approve(address(swapRouter), amountIn);
        }

        try swapRouter.swap{ value: settings.numeraire == address(0) ? amountIn : 0 }(
            poolKey,
            IPoolManager.SwapParams(
                !settings.isToken0, int256(amountOut), settings.isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta
        ) { }
        catch {
            revert("buyExactOut failed");
        }

        _trackLiquidity(poolId);
    }

    function sellExactIn(uint256 seed) public useActor(seed) {
        if (currentActor == address(0)) return;
        if (poolKeys.length == 0) return;

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();
        Settings memory settings = settingsOf[poolId];

        uint256 currentBalance = TestERC20(settings.asset).balanceOf(currentActor);
        if (currentBalance == 0) return;

        uint256 amount = currentBalance;
        TestERC20(settings.asset).approve(address(swapRouter), amount);

        try swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(
                settings.isToken0, -int256(amount), settings.isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta
        ) { }
        catch {
            revert("sellExactIn failed");
        }

        _trackLiquidity(poolId);
    }

    function sellExactOut(uint256 seed) public useActor(seed) {
        if (currentActor == address(0)) return;
        if (poolKeys.length == 0) return;

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();
        Settings memory settings = settingsOf[poolId];

        uint256 currentBalance = TestERC20(settings.asset).balanceOf(currentActor);
        if (currentBalance == 0) return;

        uint256 amountOut = currentBalance / 2;

        uint256 amountIn;
        try quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: !settings.isToken0,
                exactAmount: uint128(amountOut),
                hookData: new bytes(0)
            })
        ) returns (
            uint256 quotedAmountIn, uint256
        ) {
            amountIn = quotedAmountIn;
        } catch {
            revert("quoteExactOutputSingle failed");
        }

        TestERC20(settings.asset).approve(address(swapRouter), amountIn);

        try swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(
                settings.isToken0, int256(amountOut), settings.isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (
            BalanceDelta
        ) { }
        catch {
            revert("sellExactOut failed");
        }

        _trackLiquidity(poolId);
    }

    function setFeeDistribution(uint256 seed) public {
        if (poolKeys.length == 0) return;
        if (seed < WAD) seed = WAD;
        vm.assume(seed % 1000 > 5);

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();

        (
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        ) = _randomizeFeeDistribution(seed);

        vm.prank(settingsOf[poolId].buybackDst);
        rehypeHook.setFeeDistribution(
            poolId, assetBuybackPercentWad, numeraireBuybackPercentWad, beneficiaryPercentWad, lpPercentWad
        );
    }

    function collectFees(uint256 seed) public {
        if (poolKeys.length == 0) return;
        vm.assume(seed % 100 > 2);

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();
        address asset = settingsOf[poolId].asset;

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeHook.getHookFees(poolId);
        if (beneficiaryFees0 == 0 && beneficiaryFees1 == 0) return;

        try rehypeHook.collectFees(asset) { }
        catch {
            revert("Collect fees failed");
        }
    }

    function claimAirlockOwnerFees(uint256 seed) public {
        if (poolKeys.length == 0) return;
        vm.assume(seed % 100 > 2);

        PoolKey memory poolKey = poolKeys[seed % poolKeys.length];
        PoolId poolId = poolKey.toId();
        address asset = settingsOf[poolId].asset;

        vm.prank(AIRLOCK_OWNER);
        (,,,, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) = rehypeHook.getHookFees(poolId);
        if (airlockOwnerFees0 == 0 && airlockOwnerFees1 == 0) return;

        try rehypeHook.claimAirlockOwnerFees(asset) { } catch { }
    }

    /* --------------------------------------------------------------------------------------- */
    /*                                External helper functions                                */
    /* --------------------------------------------------------------------------------------- */

    function getPoolKey(uint256 index) external view returns (PoolKey memory) {
        return poolKeys[index];
    }

    /* --------------------------------------------------------------------------------------- */
    /*                                Internal helper functions                                */
    /* --------------------------------------------------------------------------------------- */

    function _trackLiquidity(PoolId poolId) internal {
        (,, uint256 liquidity,) = rehypeHook.getPosition(poolId);
        ghost_liquidityOf[poolId] = liquidity;
    }

    function _randomizeFeeDistribution(uint256 seed)
        internal
        pure
        returns (
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        )
    {
        assetBuybackPercentWad = seed % WAD;
        numeraireBuybackPercentWad = seed % (WAD - assetBuybackPercentWad);
        beneficiaryPercentWad = seed % (WAD - assetBuybackPercentWad - numeraireBuybackPercentWad);
        lpPercentWad = WAD - assetBuybackPercentWad - numeraireBuybackPercentWad - beneficiaryPercentWad;
    }

    function _randomizeSettings(
        uint256 seed,
        address asset,
        address numeraire
    ) internal pure returns (Settings memory settings) {
        (
            uint256 assetBuybackPercentWad,
            uint256 numeraireBuybackPercentWad,
            uint256 beneficiaryPercentWad,
            uint256 lpPercentWad
        ) = _randomizeFeeDistribution(seed);

        settings = Settings({
            asset: asset,
            numeraire: numeraire,
            buybackDst: address(0xbeef),
            customFee: 3000,
            assetBuybackPercentWad: assetBuybackPercentWad,
            numeraireBuybackPercentWad: numeraireBuybackPercentWad,
            beneficiaryPercentWad: beneficiaryPercentWad,
            lpPercentWad: lpPercentWad,
            isToken0: false
        });
    }
}
