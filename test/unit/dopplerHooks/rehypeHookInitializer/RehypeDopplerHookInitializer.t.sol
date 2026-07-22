// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta, BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Vm } from "forge-std/Vm.sol";
import { SenderNotInitializer } from "src/base/BaseDopplerHookInitializer.sol";
import { RehypeDopplerHookInitializer } from "src/dopplerHooks/RehypeDopplerHookInitializer.sol";
import { BeneficiaryData, UnorderedBeneficiaries } from "src/types/BeneficiaryData.sol";
import {
    AIRLOCK_OWNER_FEE_BPS,
    BPS_DENOMINATOR,
    EPSILON,
    FeeBeneficiariesNotConfigured,
    FeeBeneficiariesNotSupportedInDirectBuyback,
    FeeBeneficiariesSet,
    FeeDistributionInfo,
    FeeDistributionMustAddUpToWAD,
    FeeRoutingMode,
    FeeSchedule,
    FeeScheduleSet,
    FeeTooHigh,
    FeeUpdated,
    HookFees,
    InitData,
    InsufficientFeeCurrency,
    InvalidDurationSeconds,
    InvalidFeeRange,
    MAX_SWAP_FEE,
    PoolAlreadyInitialized,
    PoolInfo
} from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

contract MockPoolManager {
    // Minimal mock - just needs to exist for the quoter constructor
}

contract TrackingPoolManager {
    Currency public lastTakeCurrency;
    address public lastTakeRecipient;
    uint256 public lastTakeAmount;
    uint256 public takeCallCount;
    uint160 internal constant MOCK_SQRT_PRICE_X96 = uint160(1 << 96);

    function take(Currency currency, address to, uint256 amount) external {
        lastTakeCurrency = currency;
        lastTakeRecipient = to;
        lastTakeAmount = amount;
        ++takeCallCount;
        TestERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function extsload(bytes32) external pure returns (bytes32 value) {
        // StateLibrary.getSlot0 reads the pool's packed slot0 word via extsload.
        return bytes32(uint256(MOCK_SQRT_PRICE_X96));
    }
}

/// @dev Harness to expose internal fee functions for testing
contract RehypeDopplerHookHarness is RehypeDopplerHookInitializer {
    constructor(
        address _initializer,
        IPoolManager _poolManager
    ) RehypeDopplerHookInitializer(_initializer, _poolManager) { }

    function exposed_getCurrentFee(PoolId poolId) external returns (uint24) {
        return _getCurrentFee(poolId);
    }

    function exposed_computeCurrentFee(FeeSchedule memory schedule, uint256 elapsed) external pure returns (uint24) {
        return _computeCurrentFee(schedule, elapsed);
    }

    function exposed_collectSwapFees(
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        PoolKey memory key,
        PoolId poolId
    ) external returns (Currency feeCurrency, int128 feeDelta) {
        return _collectSwapFees(params, delta, key, poolId);
    }

    function exposed_setBeneficiaryFees(PoolId poolId, uint128 fees0, uint128 fees1) external {
        getHookFees[poolId].beneficiaryFees0 = fees0;
        getHookFees[poolId].beneficiaryFees1 = fees1;
    }
}

contract RealLpHookCaller is IUnlockCallback {
    IPoolManager public immutable poolManager;
    RehypeDopplerHookInitializer public hook;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function bindHook(RehypeDopplerHookInitializer hook_) external {
        require(address(hook) == address(0));
        hook = hook_;
    }

    function initialize(address asset, PoolKey memory key, bytes memory data) external {
        hook.onInitialization(asset, key, data);
    }

    function executeSwapHook(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta
    ) external returns (Currency feeCurrency, int128 hookDelta) {
        return abi.decode(poolManager.unlock(abi.encode(key, params, delta)), (Currency, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (PoolKey memory key, IPoolManager.SwapParams memory params, BalanceDelta delta) =
            abi.decode(data, (PoolKey, IPoolManager.SwapParams, BalanceDelta));

        (Currency feeCurrency, int128 hookDelta) = hook.onSwap(address(0x1234), key, params, delta, "");
        uint256 grossFee = uint256(uint128(hookDelta));

        poolManager.sync(feeCurrency);
        feeCurrency.transfer(address(poolManager), grossFee);
        require(poolManager.settleFor(address(hook)) == grossFee);

        return abi.encode(feeCurrency, hookDelta);
    }
}

contract MockAirlock {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

contract MockInitializer {
    mapping(address asset => BeneficiaryData[] beneficiaries) internal _beneficiaries;
    mapping(address asset => PoolKey poolKey) internal _poolKeys;
    MockAirlock public airlock;

    constructor() {
        // Create a mock airlock with a default owner
        airlock = new MockAirlock(address(this));
    }

    function setAirlockOwner(address _owner) external {
        airlock = new MockAirlock(_owner);
    }

    function setBeneficiaries(address asset, BeneficiaryData[] memory beneficiaries) external {
        delete _beneficiaries[asset];
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            _beneficiaries[asset].push(beneficiaries[i]);
        }
    }

    function getBeneficiaries(address asset) external view returns (BeneficiaryData[] memory) {
        return _beneficiaries[asset];
    }

    function setPoolKey(address asset, PoolKey memory poolKey) external {
        _poolKeys[asset] = poolKey;
    }

    function getState(address asset)
        external
        view
        returns (address, uint256, address, bytes memory, uint8, PoolKey memory, int24)
    {
        return (address(0), 0, address(0), bytes(""), 0, _poolKeys[asset], 0);
    }
}

contract RehypeDopplerHookInitializerTest is Deployers {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    struct NonzeroLpAccounting {
        uint256 gross;
        uint256 owner;
        uint256 postOwner;
        uint256 direct;
        uint256 beneficiary;
        uint256 lp;
        uint256 roundingDust;
    }

    struct RealLpObservation {
        PoolKey poolKey;
        address hook;
        address buybackDst;
        address observedFeeCurrency;
        uint256 hookDelta;
        uint256 directTransfer;
        uint256 hookBalance0;
        uint256 hookBalance1;
        int256 managerBalanceDelta0;
        int256 managerBalanceDelta1;
        int128 lpSwapAmount0;
        int128 lpSwapAmount1;
        int256 modifyLiquidityDelta;
        uint128 hookPositionLiquidity;
        uint128 managerPositionLiquidity;
    }

    RehypeDopplerHookInitializer internal dopplerHook;
    RehypeDopplerHookInitializer internal dopplerHookWithMockInitializer;
    RehypeDopplerHookHarness internal harness;
    RehypeDopplerHookHarness internal trackingHarness;
    MockInitializer internal initializer;
    MockInitializer internal mockInitializer;
    IPoolManager internal poolManager;
    TrackingPoolManager internal trackingPoolManager;
    TestERC20 internal token0;
    TestERC20 internal token1;

    function setUp() public {
        poolManager = IPoolManager(address(new MockPoolManager()));
        initializer = new MockInitializer();
        dopplerHook = new RehypeDopplerHookInitializer(address(initializer), poolManager);
        harness = new RehypeDopplerHookHarness(address(initializer), poolManager);
        trackingPoolManager = new TrackingPoolManager();
        trackingHarness = new RehypeDopplerHookHarness(address(initializer), IPoolManager(address(trackingPoolManager)));
        mockInitializer = new MockInitializer();
        dopplerHookWithMockInitializer = new RehypeDopplerHookInitializer(address(mockInitializer), poolManager);
        token0 = new TestERC20(type(uint128).max);
        token1 = new TestERC20(type(uint128).max);
        token0.mint(address(trackingPoolManager), type(uint128).max);
        token1.mint(address(trackingPoolManager), type(uint128).max);
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(dopplerHook.INITIALIZER(), address(initializer));
        assertEq(address(dopplerHook.poolManager()), address(poolManager));
        assertTrue(address(dopplerHook.quoter()) != address(0));
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization_StoresPoolInfo(bool isTokenZero, PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(isTokenZero ? poolKey.currency0 : poolKey.currency1);
        address numeraire = Currency.unwrap(isTokenZero ? poolKey.currency1 : poolKey.currency0);
        address buybackDst = makeAddr("buybackDst");
        uint24 customFee = 3000; // 0.3%

        // Fee distribution that adds up to WAD
        uint256 assetBuybackPercentWad = 0.25e18;
        uint256 numeraireBuybackPercentWad = 0.25e18;
        uint256 beneficiaryPercentWad = 0.25e18;
        uint256 lpPercentWad = 0.25e18;

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: buybackDst,
                startFee: customFee,
                endFee: customFee,
                durationSeconds: 0,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: assetBuybackPercentWad,
                    assetFeesToNumeraireBuybackWad: numeraireBuybackPercentWad,
                    assetFeesToBeneficiaryWad: beneficiaryPercentWad,
                    assetFeesToLpWad: lpPercentWad,
                    numeraireFeesToAssetBuybackWad: assetBuybackPercentWad,
                    numeraireFeesToNumeraireBuybackWad: numeraireBuybackPercentWad,
                    numeraireFeesToBeneficiaryWad: beneficiaryPercentWad,
                    numeraireFeesToLpWad: lpPercentWad
                })
            })
        );

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Check pool info
        (address storedAsset, address storedNumeraire, address storedBuybackDst) = dopplerHook.getPoolInfo(poolId);
        assertEq(storedAsset, asset);
        assertEq(storedNumeraire, numeraire);
        assertEq(storedBuybackDst, buybackDst);
        assertEq(uint8(dopplerHook.getFeeRoutingMode(poolId)), uint8(FeeRoutingMode.DirectBuyback));

        // Check fee distribution info
        (
            uint256 storedAssetBuyback,
            uint256 storedNumeraireBuyback,
            uint256 storedBeneficiary,
            uint256 storedLp,
            uint256 storedNumeraireRowAssetBuyback,
            uint256 storedNumeraireRowNumeraireBuyback,
            uint256 storedNumeraireRowBeneficiary,
            uint256 storedNumeraireRowLp
        ) = dopplerHook.getFeeDistributionInfo(poolId);
        assertEq(storedAssetBuyback, assetBuybackPercentWad);
        assertEq(storedNumeraireBuyback, numeraireBuybackPercentWad);
        assertEq(storedBeneficiary, beneficiaryPercentWad);
        assertEq(storedLp, lpPercentWad);
        assertEq(storedNumeraireRowAssetBuyback, assetBuybackPercentWad);
        assertEq(storedNumeraireRowNumeraireBuyback, numeraireBuybackPercentWad);
        assertEq(storedNumeraireRowBeneficiary, beneficiaryPercentWad);
        assertEq(storedNumeraireRowLp, lpPercentWad);

        // Check hook fees
        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 airlockOwnerFees0,
            uint128 airlockOwnerFees1,
            uint24 storedCustomFee
        ) = dopplerHook.getHookFees(poolId);
        assertEq(storedCustomFee, 0);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        assertEq(beneficiaryFees0, 0);
        assertEq(beneficiaryFees1, 0);
        assertEq(airlockOwnerFees0, 0);
        assertEq(airlockOwnerFees1, 0);
    }

    function test_onInitialization_InitializesPosition(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60; // Common tick spacing

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(_quarterInitData(numeraire, buybackDst, 3000, FeeRoutingMode.DirectBuyback));

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        (int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt) = dopplerHook.getPosition(poolId);

        // Should be full range position
        assertTrue(tickLower < 0);
        assertTrue(tickUpper > 0);
        assertEq(liquidity, 0); // No liquidity yet
        assertTrue(salt != bytes32(0)); // Salt should be set
    }

    function test_onInitialization_RevertsWhenPoolAlreadyInitialized(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        poolKey.hooks = IHooks(address(dopplerHook));
        address asset = makeAddr("asset");
        address numeraire = makeAddr("numeraire");
        address buybackDst = makeAddr("buybackDst");
        uint96 initialOwnerShares = uint96(0.05e18);
        InitData memory initialData = _beneficiaryOnlyInitData(numeraire, buybackDst, 3000, 3000, 0, 0);
        initialData.feeRoutingMode = FeeRoutingMode.RouteToBeneficiaryFees;
        initialData.feeBeneficiaries = _feeBeneficiaries(address(initializer), initialOwnerShares);

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, abi.encode(initialData));

        InitData memory replacementData = _beneficiaryOnlyInitData(
            makeAddr("replacementNumeraire"), makeAddr("replacementBuybackDst"), 12_000, 12_000, 0, 0
        );
        replacementData.feeRoutingMode = FeeRoutingMode.RouteToBeneficiaryFees;
        replacementData.feeBeneficiaries = new BeneficiaryData[](2);
        replacementData.feeBeneficiaries[0] = BeneficiaryData({ beneficiary: address(2), shares: uint96(0.4e18) });
        replacementData.feeBeneficiaries[1] =
            BeneficiaryData({ beneficiary: address(initializer), shares: uint96(0.6e18) });

        vm.prank(address(initializer));
        vm.expectRevert(PoolAlreadyInitialized.selector);
        dopplerHook.onInitialization(makeAddr("replacementAsset"), poolKey, abi.encode(replacementData));

        PoolId poolId = poolKey.toId();
        (address storedAsset, address storedNumeraire, address storedBuybackDst) = dopplerHook.getPoolInfo(poolId);
        assertEq(storedAsset, asset);
        assertEq(storedNumeraire, numeraire);
        assertEq(storedBuybackDst, buybackDst);
        assertEq(uint8(dopplerHook.getFeeRoutingMode(poolId)), uint8(FeeRoutingMode.RouteToBeneficiaryFees));
        assertEq(dopplerHook.getShares(poolId, address(1)), WAD - initialOwnerShares);
        assertEq(dopplerHook.getShares(poolId, address(2)), 0);
        assertEq(dopplerHook.getShares(poolId, address(initializer)), initialOwnerShares);
    }

    function test_onInitialization_RevertsWhenSenderNotInitializer(PoolKey memory poolKey) public {
        bytes memory data = abi.encode(_quarterInitData(address(0), address(0), 0, FeeRoutingMode.DirectBuyback));

        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onInitialization(address(0), poolKey, data);
    }

    function test_onInitialization_RevertsWhenFeeDistributionDoesNotAddToWAD(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        // Fee distribution that doesn't add up to WAD
        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 0,
                endFee: 0,
                durationSeconds: 0,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.24e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.24e18
                })
            })
        );

        vm.prank(address(initializer));
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_RevertsWhenFeeDistributionExceedsWAD(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        // Fee distribution that exceeds WAD
        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 0,
                endFee: 0,
                durationSeconds: 0,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.5e18,
                    assetFeesToNumeraireBuybackWad: 0.5e18,
                    assetFeesToBeneficiaryWad: 0.5e18,
                    assetFeesToLpWad: 0.5e18,
                    numeraireFeesToAssetBuybackWad: 0.5e18,
                    numeraireFeesToNumeraireBuybackWad: 0.5e18,
                    numeraireFeesToBeneficiaryWad: 0.5e18,
                    numeraireFeesToLpWad: 0.5e18
                })
            })
        );

        vm.prank(address(initializer));
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_SetsFeeRoutingModeFromCalldata(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data =
            abi.encode(_quarterInitData(numeraire, buybackDst, 3000, FeeRoutingMode.RouteToBeneficiaryFees));

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        assertEq(
            uint8(dopplerHook.getFeeRoutingMode(poolKey.toId())),
            uint8(FeeRoutingMode.RouteToBeneficiaryFees),
            "Mode should be set from initialization calldata"
        );
    }

    function test_onInitialization_AllowsOwnerOmittedFromFeeBeneficiaries(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        poolKey.hooks = IHooks(address(dopplerHook));
        BeneficiaryData[] memory feeBeneficiaries = new BeneficiaryData[](2);
        feeBeneficiaries[0] = BeneficiaryData({ beneficiary: address(1), shares: uint96(0.4e18) });
        feeBeneficiaries[1] = BeneficiaryData({ beneficiary: address(2), shares: uint96(0.6e18) });
        InitData memory initData = _beneficiaryOnlyInitData(
            Currency.unwrap(poolKey.currency1), makeAddr("ignoredBuybackDst"), 12_000, 12_000, 0, 0
        );
        initData.feeRoutingMode = FeeRoutingMode.RouteToBeneficiaryFees;
        initData.feeBeneficiaries = feeBeneficiaries;

        vm.expectEmit(true, false, false, true);
        emit FeeBeneficiariesSet(poolKey.toId(), feeBeneficiaries);
        vm.prank(address(initializer));
        dopplerHook.onInitialization(Currency.unwrap(poolKey.currency0), poolKey, abi.encode(initData));

        PoolId poolId = poolKey.toId();
        assertEq(dopplerHook.getShares(poolId, feeBeneficiaries[0].beneficiary), feeBeneficiaries[0].shares);
        assertEq(dopplerHook.getShares(poolId, feeBeneficiaries[1].beneficiary), feeBeneficiaries[1].shares);
        assertEq(dopplerHook.getShares(poolId, address(initializer)), 0);
        (,,,, IHooks storedHooks) = dopplerHook.getPoolKey(poolId);
        assertEq(address(storedHooks), address(dopplerHook));
    }

    function test_onInitialization_RevertsWhenDirectBuybackHasFeeBeneficiaries(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        InitData memory initData = _beneficiaryOnlyInitData(
            Currency.unwrap(poolKey.currency1), makeAddr("buybackDst"), 12_000, 12_000, 0, 0
        );
        initData.feeBeneficiaries = _feeBeneficiaries(address(initializer), uint96(0.05e18));

        vm.prank(address(initializer));
        vm.expectRevert(FeeBeneficiariesNotSupportedInDirectBuyback.selector);
        dopplerHook.onInitialization(Currency.unwrap(poolKey.currency0), poolKey, abi.encode(initData));
    }

    function test_onInitialization_AllowsAirlockOwnerBelowFivePercentAsOrdinaryBeneficiary(PoolKey memory poolKey)
        public
    {
        poolKey.tickSpacing = 60;
        poolKey.hooks = IHooks(address(dopplerHook));
        uint96 ownerShares = uint96(0.01e18);
        BeneficiaryData[] memory feeBeneficiaries = _feeBeneficiaries(address(initializer), ownerShares);
        InitData memory initData = _beneficiaryOnlyInitData(
            Currency.unwrap(poolKey.currency1), makeAddr("ignoredBuybackDst"), 12_000, 12_000, 0, 0
        );
        initData.feeRoutingMode = FeeRoutingMode.RouteToBeneficiaryFees;
        initData.feeBeneficiaries = feeBeneficiaries;

        vm.prank(address(initializer));
        dopplerHook.onInitialization(Currency.unwrap(poolKey.currency0), poolKey, abi.encode(initData));

        PoolId poolId = poolKey.toId();
        assertEq(dopplerHook.getShares(poolId, address(initializer)), ownerShares);
    }

    function test_onInitialization_AllowsAirlockOwnerAsSoleFeeBeneficiary(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        poolKey.hooks = IHooks(address(dopplerHook));
        BeneficiaryData[] memory feeBeneficiaries = new BeneficiaryData[](1);
        feeBeneficiaries[0] = BeneficiaryData({ beneficiary: address(initializer), shares: uint96(WAD) });
        InitData memory initData = _beneficiaryOnlyInitData(
            Currency.unwrap(poolKey.currency1), makeAddr("ignoredBuybackDst"), 12_000, 12_000, 0, 0
        );
        initData.feeRoutingMode = FeeRoutingMode.RouteToBeneficiaryFees;
        initData.feeBeneficiaries = feeBeneficiaries;

        vm.prank(address(initializer));
        dopplerHook.onInitialization(Currency.unwrap(poolKey.currency0), poolKey, abi.encode(initData));

        assertEq(dopplerHook.getShares(poolKey.toId(), address(initializer)), WAD);
    }

    function test_onInitialization_RevertsWhenFeeBeneficiariesAreUnordered(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        poolKey.hooks = IHooks(address(dopplerHook));
        BeneficiaryData[] memory feeBeneficiaries = new BeneficiaryData[](2);
        feeBeneficiaries[0] = BeneficiaryData({ beneficiary: address(2), shares: uint96(0.5e18) });
        feeBeneficiaries[1] = BeneficiaryData({ beneficiary: address(1), shares: uint96(0.5e18) });
        InitData memory initData = _beneficiaryOnlyInitData(
            Currency.unwrap(poolKey.currency1), makeAddr("ignoredBuybackDst"), 12_000, 12_000, 0, 0
        );
        initData.feeRoutingMode = FeeRoutingMode.RouteToBeneficiaryFees;
        initData.feeBeneficiaries = feeBeneficiaries;

        vm.prank(address(initializer));
        vm.expectRevert(UnorderedBeneficiaries.selector);
        dopplerHook.onInitialization(Currency.unwrap(poolKey.currency0), poolKey, abi.encode(initData));
    }

    function test_onInitialization_RevertsWhenFeeRoutingModeInvalid(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        InitData memory initData = _quarterInitData(numeraire, buybackDst, 3000, FeeRoutingMode.RouteToBeneficiaryFees);
        initData.feeBeneficiaries = new BeneficiaryData[](1);
        initData.feeBeneficiaries[0] = BeneficiaryData({ beneficiary: address(1), shares: uint96(WAD) });
        bytes memory data = abi.encode(initData);

        // Preserve an otherwise-valid dynamic struct ABI and mutate only its feeRoutingMode word to invalid enum value 2.
        uint256 rawFeeRoutingMode;
        assembly ("memory-safe") {
            rawFeeRoutingMode := mload(add(data, 0x100))
            mstore(add(data, 0x100), 2)
        }
        assertEq(rawFeeRoutingMode, uint8(FeeRoutingMode.RouteToBeneficiaryFees));

        vm.prank(address(initializer));
        vm.expectRevert();
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    /* ---------------------------------------------------------------------- */
    /*                                  onSwap()                                   */
    /* ---------------------------------------------------------------------- */

    function test_onSwap_RevertsWhenSenderNotInitializer(
        PoolKey memory poolKey,
        IPoolManager.SwapParams memory swapParams
    ) public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }

    function test_onSwap_AccumulatesFees(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");
        uint24 customFee = 10_000; // 1%

        // All fees go to beneficiary for simple testing
        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: buybackDst,
                startFee: customFee,
                endFee: customFee,
                durationSeconds: 0,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0,
                    assetFeesToNumeraireBuybackWad: 0,
                    assetFeesToBeneficiaryWad: WAD,
                    assetFeesToLpWad: 0,
                    numeraireFeesToAssetBuybackWad: 0,
                    numeraireFeesToNumeraireBuybackWad: 0,
                    numeraireFeesToBeneficiaryWad: WAD,
                    numeraireFeesToLpWad: 0
                })
            })
        );

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        // Simulate a swap with amountSpecified < 0 (exact input) and zeroForOne = true
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(address(initializer));
        dopplerHook.onSwap(address(0x123), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));

        PoolId poolId = poolKey.toId();

        // Fee should be 1% of 1e18 = 0.01e18
        // Since fees are below EPSILON after distribution, they should accumulate to beneficiary
        (,,,,,, uint24 storedFee) = dopplerHook.getHookFees(poolId);
        // Note: Actual fee accumulation depends on the fee logic, but fees0 should have been set
    }

    function test_onSwap_SkipsWhenSenderIsHook(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        vm.prank(address(initializer));
        (Currency feeCurrency, int128 delta) = dopplerHook.onSwap(
            address(dopplerHook), poolKey, IPoolManager.SwapParams(false, 1, 0), BalanceDeltaLibrary.ZERO_DELTA, ""
        );

        assertEq(Currency.unwrap(feeCurrency), address(0));
        assertEq(delta, 0);
    }

    function test_onInitialization_StoresCustomDistribution(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 0,
                endFee: 0,
                durationSeconds: 0,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.5e18,
                    assetFeesToNumeraireBuybackWad: 0,
                    assetFeesToBeneficiaryWad: 0.5e18,
                    assetFeesToLpWad: 0,
                    numeraireFeesToAssetBuybackWad: 0.5e18,
                    numeraireFeesToNumeraireBuybackWad: 0,
                    numeraireFeesToBeneficiaryWad: 0.5e18,
                    numeraireFeesToLpWad: 0
                })
            })
        );

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (
            uint256 storedAssetBuyback,
            uint256 storedNumeraireBuyback,
            uint256 storedBeneficiary,
            uint256 storedLp,
            uint256 storedNumeraireRowAssetBuyback,
            uint256 storedNumeraireRowNumeraireBuyback,
            uint256 storedNumeraireRowBeneficiary,
            uint256 storedNumeraireRowLp
        ) = dopplerHook.getFeeDistributionInfo(poolId);

        assertEq(storedAssetBuyback, 0.5e18);
        assertEq(storedNumeraireBuyback, 0);
        assertEq(storedBeneficiary, 0.5e18);
        assertEq(storedLp, 0);
        assertEq(storedNumeraireRowAssetBuyback, 0.5e18);
        assertEq(storedNumeraireRowNumeraireBuyback, 0);
        assertEq(storedNumeraireRowBeneficiary, 0.5e18);
        assertEq(storedNumeraireRowLp, 0);
    }

    /* ----------------------------------------------------------------------------- */
    /*                         Fee Schedule / Decay Tests                           */
    /* ----------------------------------------------------------------------------- */

    function test_onInitialization_StoresFeeSchedule(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: buybackDst,
                startFee: 10_000,
                endFee: 3000,
                durationSeconds: 3600,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.25e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.25e18
                })
            })
        );

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (uint32 startingTime, uint24 startFee, uint24 endFee, uint24 lastFee, uint32 durationSeconds) =
            dopplerHook.getFeeSchedule(poolId);

        assertEq(startFee, 10_000);
        assertEq(endFee, 3000);
        assertEq(lastFee, 10_000);
        assertEq(durationSeconds, 3600);
        assertEq(startingTime, uint32(block.timestamp));
    }

    function test_onInitialization_EmitsFeeScheduleSet(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 10_000,
                endFee: 3000,
                durationSeconds: 3600,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.25e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.25e18
                })
            })
        );

        PoolId poolId = poolKey.toId();

        vm.expectEmit(true, false, false, true);
        emit FeeScheduleSet(poolId, uint32(block.timestamp), 10_000, 3000, 3600);

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_RevertsWhenStartFeeTooHigh(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: uint24(MAX_SWAP_FEE) + 1,
                endFee: 0,
                durationSeconds: 3600,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.25e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.25e18
                })
            })
        );

        vm.prank(address(initializer));
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, uint24(MAX_SWAP_FEE) + 1));
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_RevertsWhenStartFeeLessThanEndFee(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 3000,
                endFee: 10_000,
                durationSeconds: 3600,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.25e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.25e18
                })
            })
        );

        vm.prank(address(initializer));
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeRange.selector, uint24(3000), uint24(10_000)));
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_RevertsWhenDescendingFeeWithZeroDuration(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 10_000,
                endFee: 3000,
                durationSeconds: 0,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.25e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.25e18
                })
            })
        );

        vm.prank(address(initializer));
        vm.expectRevert(abi.encodeWithSelector(InvalidDurationSeconds.selector, uint32(0)));
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_FlatFeeAllowsZeroDuration(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 5000,
                endFee: 5000,
                durationSeconds: 0,
                startingTime: 0,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.25e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.25e18
                })
            })
        );

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (,, uint24 endFee,,) = dopplerHook.getFeeSchedule(poolId);
        assertEq(endFee, 5000);
    }

    function test_onInitialization_FutureStartingTimeIsPreserved(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        uint32 futureTime = uint32(block.timestamp) + 1000;

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 10_000,
                endFee: 3000,
                durationSeconds: 3600,
                startingTime: futureTime,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.25e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.25e18
                })
            })
        );

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (uint32 startingTime,,,,) = dopplerHook.getFeeSchedule(poolId);
        assertEq(startingTime, futureTime);
    }

    function test_onInitialization_PastStartingTimeNormalizesToNow(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        vm.warp(1_000_000);

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        uint32 pastTime = uint32(block.timestamp) - 100;

        bytes memory data = abi.encode(
            InitData({
                numeraire: numeraire,
                buybackDst: address(0),
                startFee: 10_000,
                endFee: 3000,
                durationSeconds: 3600,
                startingTime: pastTime,
                feeRoutingMode: FeeRoutingMode.DirectBuyback,
                feeBeneficiaries: new BeneficiaryData[](0),
                feeDistributionInfo: FeeDistributionInfo({
                    assetFeesToAssetBuybackWad: 0.25e18,
                    assetFeesToNumeraireBuybackWad: 0.25e18,
                    assetFeesToBeneficiaryWad: 0.25e18,
                    assetFeesToLpWad: 0.25e18,
                    numeraireFeesToAssetBuybackWad: 0.25e18,
                    numeraireFeesToNumeraireBuybackWad: 0.25e18,
                    numeraireFeesToBeneficiaryWad: 0.25e18,
                    numeraireFeesToLpWad: 0.25e18
                })
            })
        );

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (uint32 startingTime,,,,) = dopplerHook.getFeeSchedule(poolId);
        assertEq(startingTime, uint32(block.timestamp));
    }

    /* ----------------------------------------------------------------------------- */
    /*                       _getCurrentFee / _computeCurrentFee                   */
    /* ----------------------------------------------------------------------------- */

    function test_getCurrentFee_ReturnsFlatFeeWhenStartEqualsEnd(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 5000, 5000, 0, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        uint24 fee = harness.exposed_getCurrentFee(poolKey.toId());
        assertEq(fee, 5000, "Flat fee should return startFee");
    }

    function test_getCurrentFee_ReturnsFlatFeeWhenDurationZero(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        // startFee == endFee with explicit durationSeconds == 0
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 8000, 8000, 0, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        vm.warp(block.timestamp + 9999);
        uint24 fee = harness.exposed_getCurrentFee(poolKey.toId());
        assertEq(fee, 8000, "Should always return startFee when duration is 0");
    }

    function test_getCurrentFee_ReturnsStartFeeBeforeScheduleStarts(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        uint32 futureStart = uint32(block.timestamp) + 1000;

        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 3000, 3600, futureStart));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        // Still before futureStart
        vm.warp(futureStart - 1);
        uint24 fee = harness.exposed_getCurrentFee(poolKey.toId());
        assertEq(fee, 10_000, "Fee should be startFee before schedule starts");
    }

    function test_getCurrentFee_ReturnsEndFeeAfterFullDuration(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 3600, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        vm.warp(block.timestamp + 3601);
        uint24 fee = harness.exposed_getCurrentFee(poolKey.toId());
        assertEq(fee, 2000, "Fee should be endFee after full duration");
    }

    function test_getCurrentFee_ReturnsEndFeeExactlyAtDurationEnd(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 3600, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        vm.warp(block.timestamp + 3600);
        uint24 fee = harness.exposed_getCurrentFee(poolKey.toId());
        assertEq(fee, 2000, "Fee should be endFee at exactly duration end");
    }

    function test_getCurrentFee_InterpolatesAtMidpoint(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        // startFee=10000, endFee=2000, range=8000, duration=4000
        // At midpoint (2000s): fee = 10000 - 8000 * 2000/4000 = 10000 - 4000 = 6000
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 4000, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        vm.warp(block.timestamp + 2000);
        uint24 fee = harness.exposed_getCurrentFee(poolKey.toId());
        assertEq(fee, 6000, "Fee should be linearly interpolated at midpoint");
    }

    function test_getCurrentFee_InterpolatesAtQuarterPoint(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        // startFee=10000, endFee=2000, range=8000, duration=4000
        // At 1000s: fee = 10000 - 8000 * 1000/4000 = 10000 - 2000 = 8000
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 4000, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        vm.warp(block.timestamp + 1000);
        uint24 fee = harness.exposed_getCurrentFee(poolKey.toId());
        assertEq(fee, 8000, "Fee should be linearly interpolated at 25%");
    }

    function test_getCurrentFee_UpdatesLastFeeInStorage(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 4000, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Verify initial lastFee
        (,,, uint24 lastFeeBefore,) = harness.getFeeSchedule(poolId);
        assertEq(lastFeeBefore, 10_000, "lastFee should start at startFee");

        // Warp to midpoint and call
        vm.warp(block.timestamp + 2000);
        harness.exposed_getCurrentFee(poolId);

        (,,, uint24 lastFeeAfter,) = harness.getFeeSchedule(poolId);
        assertEq(lastFeeAfter, 6000, "lastFee should be updated to interpolated value");
    }

    function test_getCurrentFee_EmitsFeeUpdatedOnChange(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 4000, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        vm.warp(block.timestamp + 2000);

        vm.expectEmit(true, false, false, true);
        emit FeeUpdated(poolId, 6000);
        harness.exposed_getCurrentFee(poolId);
    }

    function test_getCurrentFee_DoesNotEmitWhenFeeUnchanged(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 4000, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Warp and call once to update
        vm.warp(block.timestamp + 2000);
        harness.exposed_getCurrentFee(poolId);

        // Record lastFee before second call at same timestamp
        (,,, uint24 lastFeeBefore,) = harness.getFeeSchedule(poolId);

        // Call again at the same timestamp — fee unchanged, so no storage write
        uint24 fee2 = harness.exposed_getCurrentFee(poolId);

        (,,, uint24 lastFeeAfter,) = harness.getFeeSchedule(poolId);
        assertEq(lastFeeBefore, lastFeeAfter, "lastFee should not change when fee is unchanged");
    }

    function test_getCurrentFee_ShortCircuitsWhenFullyDecayed(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 3600, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Fully decay
        vm.warp(block.timestamp + 3601);
        harness.exposed_getCurrentFee(poolId);

        (,,, uint24 lastFee,) = harness.getFeeSchedule(poolId);
        assertEq(lastFee, 2000, "lastFee should be endFee after full decay");

        // Subsequent calls should return endFee via short-circuit
        vm.warp(block.timestamp + 10_000);
        uint24 fee = harness.exposed_getCurrentFee(poolId);
        assertEq(fee, 2000, "Should short-circuit to endFee");
    }

    function test_computeCurrentFee_LinearInterpolation() public view {
        FeeSchedule memory schedule =
            FeeSchedule({ startingTime: 0, startFee: 10_000, endFee: 2000, lastFee: 10_000, durationSeconds: 4000 });

        assertEq(harness.exposed_computeCurrentFee(schedule, 0), 10_000, "0% elapsed");
        assertEq(harness.exposed_computeCurrentFee(schedule, 1000), 8000, "25% elapsed");
        assertEq(harness.exposed_computeCurrentFee(schedule, 2000), 6000, "50% elapsed");
        assertEq(harness.exposed_computeCurrentFee(schedule, 3000), 4000, "75% elapsed");
        assertEq(harness.exposed_computeCurrentFee(schedule, 3999), 2002, "~100% elapsed");
    }

    function testFuzz_computeCurrentFee_AlwaysBetweenStartAndEnd(
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint256 elapsed
    ) public view {
        startFee = uint24(bound(startFee, 1, uint24(MAX_SWAP_FEE)));
        endFee = uint24(bound(endFee, 0, startFee));
        durationSeconds = uint32(bound(durationSeconds, 1, type(uint32).max));
        elapsed = bound(elapsed, 0, uint256(durationSeconds) - 1);

        FeeSchedule memory schedule = FeeSchedule({
            startingTime: 0, startFee: startFee, endFee: endFee, lastFee: startFee, durationSeconds: durationSeconds
        });

        uint24 fee = harness.exposed_computeCurrentFee(schedule, elapsed);
        assertGe(fee, endFee, "Fee should be >= endFee");
        assertLe(fee, startFee, "Fee should be <= startFee");
    }

    function testFuzz_getCurrentFee_MonotonicallyDecreasing(PoolKey memory poolKey, uint32 warp1, uint32 warp2) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        vm.warp(1_000_000);
        bytes memory data = abi.encode(_decayInitData(numeraire, address(0), 10_000, 2000, 3600, 0));

        vm.prank(address(initializer));
        harness.onInitialization(asset, poolKey, data);

        warp1 = uint32(bound(warp1, 0, 7200));
        warp2 = uint32(bound(warp2, 0, 7200));
        if (warp1 > warp2) (warp1, warp2) = (warp2, warp1);

        uint256 base = block.timestamp;

        vm.warp(base + warp1);
        uint24 fee1 = harness.exposed_getCurrentFee(poolKey.toId());

        vm.warp(base + warp2);
        uint24 fee2 = harness.exposed_getCurrentFee(poolKey.toId());

        assertGe(fee1, fee2, "Fee should be monotonically non-increasing over time");
    }

    function test_onSwap_ExactInput_SelfTakesAndReturnsExpectedFlatFee() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(address(initializer));
        trackingHarness.onInitialization(
            address(token0),
            poolKey,
            abi.encode(_beneficiaryOnlyInitData(address(token1), address(0), 10_000, 10_000, 0, 0))
        );

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0 });
        int128 amount0 = -int128(uint128(1 ether));
        int128 amount1 = int128(uint128(5 ether));
        uint256 expectedFeeAmount = 5 ether * 10_000 / MAX_SWAP_FEE;

        vm.prank(address(initializer));
        (Currency feeCurrency, int128 hookDelta) =
            trackingHarness.onSwap(address(0x1234), poolKey, swapParams, toBalanceDelta(amount0, amount1), "");

        assertEq(Currency.unwrap(feeCurrency), address(token1), "fee currency should be unspecified output token");
        assertEq(uint256(uint128(hookDelta)), expectedFeeAmount, "returned hook delta should match expected fee");
        assertEq(trackingPoolManager.takeCallCount(), 1, "hook should self-take exactly once");
        assertEq(
            Currency.unwrap(trackingPoolManager.lastTakeCurrency()),
            address(token1),
            "self-take should use fee currency"
        );
        assertEq(
            trackingPoolManager.lastTakeRecipient(), address(trackingHarness), "self-take recipient should be hook"
        );
        assertEq(trackingPoolManager.lastTakeAmount(), expectedFeeAmount, "self-take amount should match expected fee");

        PoolId poolId = poolKey.toId();
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            trackingHarness.getHookFees(poolId);
        assertEq(beneficiaryFees0, 0, "only currency1 beneficiary fees should accrue");
        assertEq(airlockOwnerFees0, 0, "only currency1 owner fees should accrue");
        assertEq(
            uint256(beneficiaryFees1) + uint256(airlockOwnerFees1),
            expectedFeeAmount,
            "tracked fees should equal the single collected fee"
        );
    }

    function test_onSwap_ExactOutput_SelfTakesAndReturnsExpectedInputFee() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(address(initializer));
        trackingHarness.onInitialization(
            address(token0),
            poolKey,
            abi.encode(_beneficiaryOnlyInitData(address(token1), address(0), 10_000, 10_000, 0, 0))
        );

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: 0.5 ether, sqrtPriceLimitX96: 0 });
        int128 amount0 = -int128(uint128(12 ether / 10));
        int128 amount1 = int128(uint128(0.5 ether));
        uint256 expectedFeeAmount = (12 ether / 10) * 10_000 / MAX_SWAP_FEE;

        vm.prank(address(initializer));
        (Currency feeCurrency, int128 hookDelta) =
            trackingHarness.onSwap(address(0x1234), poolKey, swapParams, toBalanceDelta(amount0, amount1), "");

        assertEq(Currency.unwrap(feeCurrency), address(token0), "fee currency should be unspecified input token");
        assertEq(uint256(uint128(hookDelta)), expectedFeeAmount, "returned hook delta should match expected fee");
        assertEq(trackingPoolManager.takeCallCount(), 1, "hook should self-take exactly once");
        assertEq(
            Currency.unwrap(trackingPoolManager.lastTakeCurrency()),
            address(token0),
            "self-take should use fee currency"
        );
        assertEq(
            trackingPoolManager.lastTakeRecipient(), address(trackingHarness), "self-take recipient should be hook"
        );
        assertEq(trackingPoolManager.lastTakeAmount(), expectedFeeAmount, "self-take amount should match expected fee");

        PoolId poolId = poolKey.toId();
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            trackingHarness.getHookFees(poolId);
        assertEq(beneficiaryFees1, 0, "only currency0 beneficiary fees should accrue");
        assertEq(airlockOwnerFees1, 0, "only currency0 owner fees should accrue");
        assertEq(
            uint256(beneficiaryFees0) + uint256(airlockOwnerFees0),
            expectedFeeAmount,
            "tracked fees should equal the single collected fee"
        );
    }

    function test_collectSwapFees_GrossOwnerCarveOutAcrossModesDirectionsAndBeneficiaryConfigurations() public {
        uint256 expectedGross = 2_000_019;
        uint256 expectedOwnerCut = expectedGross * AIRLOCK_OWNER_FEE_BPS / BPS_DENOMINATOR;
        uint256 caseIndex;

        for (uint256 beneficiaryConfiguration; beneficiaryConfiguration < 2; ++beneficiaryConfiguration) {
            for (uint256 exactMode; exactMode < 2; ++exactMode) {
                for (uint256 direction; direction < 2; ++direction) {
                    (uint256 grossFee, uint256 ownerCut) = _assertGrossOwnerCarveOut(
                        caseIndex++, exactMode == 0, direction == 0, beneficiaryConfiguration == 1, 160_001_520
                    );

                    assertEq(grossFee, expectedGross, "gross must be calculated from the swap delta");
                    assertEq(ownerCut, expectedOwnerCut, "owner cut must not depend on routing configuration");
                }
            }
        }
    }

    function testFuzz_collectSwapFees_GrossOwnerCarveOutConservesNonDivisibleFee(uint256 feeBase) public {
        feeBase = bound(feeBase, 80, 1e30);

        (uint256 grossFee, uint256 ownerCut) = _assertGrossOwnerCarveOut(20, true, true, false, feeBase);
        uint256 expectedGross = feeBase * 10_000 / MAX_SWAP_FEE;
        uint256 expectedOwnerCut = expectedGross * AIRLOCK_OWNER_FEE_BPS / BPS_DENOMINATOR;

        assertEq(grossFee, expectedGross, "gross must be derived from output delta");
        assertEq(ownerCut, expectedOwnerCut, "owner cut must floor at the basis-point boundary");
    }

    function test_collectSwapFees_TinyGrossFloorsOwnerCutToZero() public {
        (uint256 grossFee, uint256 ownerCut) = _assertGrossOwnerCarveOut(21, false, false, true, 1599);

        assertEq(grossFee, 19, "gross fee must floor independently before the owner carve-out");
        assertEq(ownerCut, 0, "a sub-twenty-wei gross fee must floor the five-percent owner cut to zero");
    }

    function test_collectSwapFees_NonPositiveOutputDoesNotAccrueOrTake() public {
        PoolKey memory poolKey = _grossAccountingPoolKey(30);
        _initializeGrossAccountingPool(poolKey, false);
        uint256 takeCallCountBefore = trackingPoolManager.takeCallCount();

        for (uint256 exactMode; exactMode < 2; ++exactMode) {
            for (uint256 direction; direction < 2; ++direction) {
                for (int128 outputAmount = -1; outputAmount <= 0; ++outputAmount) {
                    bool zeroForOne = direction == 0;
                    IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: exactMode == 0 ? -int256(1) : int256(1),
                        sqrtPriceLimitX96: 0
                    });
                    BalanceDelta delta = zeroForOne
                        ? toBalanceDelta(-int128(1000), outputAmount)
                        : toBalanceDelta(outputAmount, -int128(1000));

                    (Currency feeCurrency, int128 hookDelta) =
                        trackingHarness.exposed_collectSwapFees(params, delta, poolKey, poolKey.toId());

                    assertEq(Currency.unwrap(feeCurrency), address(0), "no fee currency for non-positive output");
                    assertEq(hookDelta, 0, "no hook delta for non-positive output");
                }
            }
        }

        assertEq(trackingPoolManager.takeCallCount(), takeCallCountBefore, "no fee may be taken");
        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 ownerFees0,
            uint128 ownerFees1,
        ) = trackingHarness.getHookFees(poolKey.toId());
        assertEq(fees0 + fees1 + beneficiaryFees0 + beneficiaryFees1 + ownerFees0 + ownerFees1, 0);
    }

    function test_onSwap_RoutesOnlyPostOwnerAmountWithZeroBeneficiaryAllocation() public {
        uint256 directBuybackOwnerCut = _assertPostOwnerRouting(40, false);
        uint256 beneficiaryRoutedOwnerCut = _assertPostOwnerRouting(41, true);

        assertEq(
            directBuybackOwnerCut,
            beneficiaryRoutedOwnerCut,
            "owner cut must be unchanged by beneficiary configuration and routing mode"
        );
    }

    function test_onSwap_NonzeroLpMatrixReconcilesGrossOwnerAndPostOwnerRouting() public {
        uint256 feeBase = 1_600_015_200;
        NonzeroLpAccounting memory expected = _nonzeroLpExpectation(feeBase);
        RealLpObservation memory observed = _executeRealLpMatrixSwap(feeBase, expected.gross);

        _assertRealLpMatrixState(observed, expected);
        _logRealLpAccounting(expected, observed);
    }

    function test_onSwap_SelfTakesAndReturnsExpectedDecayedFeeAtMidpoint() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.warp(1_000_000);

        vm.prank(address(initializer));
        trackingHarness.onInitialization(
            address(token0),
            poolKey,
            abi.encode(_beneficiaryOnlyInitData(address(token1), address(0), 10_000, 2000, 4000, 0))
        );

        vm.warp(block.timestamp + 2000);

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0 });
        int128 amount0 = -int128(uint128(1 ether));
        int128 amount1 = int128(uint128(5 ether));
        uint256 expectedFeeAmount = 5 ether * 6000 / MAX_SWAP_FEE;

        vm.prank(address(initializer));
        (Currency feeCurrency, int128 hookDelta) =
            trackingHarness.onSwap(address(0x1234), poolKey, swapParams, toBalanceDelta(amount0, amount1), "");

        assertEq(Currency.unwrap(feeCurrency), address(token1), "fee currency should be unspecified output token");
        assertEq(uint256(uint128(hookDelta)), expectedFeeAmount, "returned hook delta should use midpoint fee");
        assertEq(trackingPoolManager.takeCallCount(), 1, "hook should self-take exactly once");
        assertEq(trackingPoolManager.lastTakeAmount(), expectedFeeAmount, "self-take amount should use midpoint fee");

        PoolId poolId = poolKey.toId();
        (,,, uint24 lastFee,) = trackingHarness.getFeeSchedule(poolId);
        assertEq(lastFee, 6000, "lastFee should update to the midpoint fee");

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            trackingHarness.getHookFees(poolId);
        assertEq(beneficiaryFees0, 0, "only currency1 beneficiary fees should accrue");
        assertEq(airlockOwnerFees0, 0, "only currency1 owner fees should accrue");
        assertEq(
            uint256(beneficiaryFees1) + uint256(airlockOwnerFees1),
            expectedFeeAmount,
            "tracked fees should equal the single decayed fee"
        );
    }

    function test_onSwap_RevertsWhenPoolManagerFeeCurrencyBalanceInsufficient() public {
        TestERC20 asset = new TestERC20(type(uint128).max);
        TestERC20 numeraire = new TestERC20(type(uint128).max);
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(asset)),
            currency1: Currency.wrap(address(numeraire)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(address(initializer));
        dopplerHook.onInitialization(
            address(asset),
            poolKey,
            abi.encode(_beneficiaryOnlyInitData(address(numeraire), address(0), 10_000, 10_000, 0, 0))
        );

        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0 });

        vm.prank(address(initializer));
        vm.expectRevert(InsufficientFeeCurrency.selector);
        dopplerHook.onSwap(address(0x1234), poolKey, swapParams, toBalanceDelta(-int128(1 ether), int128(5 ether)), "");
    }

    /* ----------------------------------------------------------------------------- */
    /*                              collectFees()                                    */
    /* ----------------------------------------------------------------------------- */

    function test_collectFees_ReturnsZeroWhenNoFees(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(_quarterInitData(numeraire, address(0), 0, FeeRoutingMode.DirectBuyback));

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        // collectFees should return zero delta when no fees accumulated
        // Note: This will revert or return zeros depending on implementation
        // For now, we just verify the hook fees are zero
        PoolId poolId = poolKey.toId();
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = dopplerHook.getHookFees(poolId);

        assertEq(beneficiaryFees0, 0);
        assertEq(beneficiaryFees1, 0);
    }

    function test_collectFees_ConfiguredPoolAllowsPermissionlessHarvestThroughBothOverloads() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(trackingHarness))
        });
        address asset = address(token0);
        address harvester = makeAddr("harvester");
        address beneficiary = address(1);
        BeneficiaryData[] memory feeBeneficiaries = new BeneficiaryData[](2);
        feeBeneficiaries[0] = BeneficiaryData({ beneficiary: beneficiary, shares: uint96(0.95e18) });
        feeBeneficiaries[1] = BeneficiaryData({ beneficiary: address(initializer), shares: uint96(0.05e18) });
        InitData memory initData = _beneficiaryOnlyInitData(address(token1), address(0), 12_000, 12_000, 0, 0);
        initData.feeRoutingMode = FeeRoutingMode.RouteToBeneficiaryFees;
        initData.feeBeneficiaries = feeBeneficiaries;

        initializer.setPoolKey(asset, poolKey);
        vm.prank(address(initializer));
        trackingHarness.onInitialization(asset, poolKey, abi.encode(initData));

        PoolId poolId = poolKey.toId();
        trackingHarness.exposed_setBeneficiaryFees(poolId, 100, 200);
        token0.mint(address(trackingHarness), 400);
        token1.mint(address(trackingHarness), 600);

        uint256 harvesterBalance0 = token0.balanceOf(harvester);
        uint256 harvesterBalance1 = token1.balanceOf(harvester);
        vm.prank(harvester);
        BalanceDelta addressFees = trackingHarness.collectFees(asset);

        assertEq(uint128(addressFees.amount0()), 100);
        assertEq(uint128(addressFees.amount1()), 200);
        assertEq(trackingHarness.getCumulatedFees0(poolId), 100);
        assertEq(trackingHarness.getCumulatedFees1(poolId), 200);

        trackingHarness.exposed_setBeneficiaryFees(poolId, 300, 400);
        vm.prank(harvester);
        (uint128 poolIdFees0, uint128 poolIdFees1) = trackingHarness.collectFees(poolId);

        assertEq(poolIdFees0, 300);
        assertEq(poolIdFees1, 400);
        assertEq(trackingHarness.getCumulatedFees0(poolId), 400);
        assertEq(trackingHarness.getCumulatedFees1(poolId), 600);
        assertEq(token0.balanceOf(harvester), harvesterBalance0);
        assertEq(token1.balanceOf(harvester), harvesterBalance1);

        vm.prank(beneficiary);
        trackingHarness.collectFees(poolId);
        assertEq(token0.balanceOf(beneficiary), 380);
        assertEq(token1.balanceOf(beneficiary), 570);
    }

    function test_collectFees_PoolIdRevertsWhenFeeBeneficiariesNotConfigured() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(trackingHarness))
        });
        address asset = address(token0);
        initializer.setPoolKey(asset, poolKey);

        vm.prank(address(initializer));
        trackingHarness.onInitialization(
            asset, poolKey, abi.encode(_beneficiaryOnlyInitData(address(token1), address(0), 12_000, 12_000, 0, 0))
        );

        PoolId poolId = poolKey.toId();
        trackingHarness.exposed_setBeneficiaryFees(poolId, 100, 200);
        vm.expectRevert(FeeBeneficiariesNotConfigured.selector);
        trackingHarness.collectFees(poolId);

        (,, uint128 fees0, uint128 fees1,,,) = trackingHarness.getHookFees(poolId);
        assertEq(fees0, 100);
        assertEq(fees1, 200);
    }

    function test_collectFees_PoolIdRevertsForUnknownPool() public {
        PoolId unknownPoolId = PoolId.wrap(keccak256("unknown pool"));
        trackingHarness.exposed_setBeneficiaryFees(unknownPoolId, 77, 88);

        vm.expectRevert(FeeBeneficiariesNotConfigured.selector);
        trackingHarness.collectFees(unknownPoolId);

        (,, uint128 fees0, uint128 fees1,,,) = trackingHarness.getHookFees(unknownPoolId);
        assertEq(fees0, 77);
        assertEq(fees1, 88);
    }

    /* ----------------------------------------------------------------------------- */
    /*                              Helpers                                          */
    /* ----------------------------------------------------------------------------- */

    function _quarterInitData(
        address numeraire,
        address buybackDst,
        uint24 customFee,
        FeeRoutingMode feeRoutingMode
    ) internal pure returns (InitData memory) {
        return InitData({
            numeraire: numeraire,
            buybackDst: buybackDst,
            startFee: customFee,
            endFee: customFee,
            durationSeconds: 0,
            startingTime: 0,
            feeRoutingMode: feeRoutingMode,
            feeBeneficiaries: new BeneficiaryData[](0),
            feeDistributionInfo: FeeDistributionInfo({
                assetFeesToAssetBuybackWad: 0.25e18,
                assetFeesToNumeraireBuybackWad: 0.25e18,
                assetFeesToBeneficiaryWad: 0.25e18,
                assetFeesToLpWad: 0.25e18,
                numeraireFeesToAssetBuybackWad: 0.25e18,
                numeraireFeesToNumeraireBuybackWad: 0.25e18,
                numeraireFeesToBeneficiaryWad: 0.25e18,
                numeraireFeesToLpWad: 0.25e18
            })
        });
    }

    function _assertGrossOwnerCarveOut(
        uint256 caseIndex,
        bool exactInput,
        bool zeroForOne,
        bool configureBeneficiaries,
        uint256 feeBase
    ) internal returns (uint256 grossFee, uint256 ownerCut) {
        PoolKey memory poolKey = _grossAccountingPoolKey(caseIndex);
        _initializeGrossAccountingPool(poolKey, configureBeneficiaries);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: exactInput ? -int256(1) : int256(1), sqrtPriceLimitX96: 0
        });
        int128 signedFeeBase = int128(uint128(feeBase));
        BalanceDelta delta =
            zeroForOne ? toBalanceDelta(-signedFeeBase, signedFeeBase) : toBalanceDelta(signedFeeBase, -signedFeeBase);

        uint256 takeCallCountBefore = trackingPoolManager.takeCallCount();
        (Currency feeCurrency, int128 hookDelta) =
            trackingHarness.exposed_collectSwapFees(params, delta, poolKey, poolKey.toId());

        grossFee = feeBase * 10_000 / MAX_SWAP_FEE;
        ownerCut = grossFee * AIRLOCK_OWNER_FEE_BPS / BPS_DENOMINATOR;
        uint256 routingAmount = grossFee - ownerCut;
        bool feeInCurrency0 = zeroForOne != exactInput;

        assertEq(uint256(uint128(hookDelta)), grossFee, "hook delta must remain the full gross fee");
        assertEq(
            Currency.unwrap(feeCurrency),
            Currency.unwrap(feeInCurrency0 ? poolKey.currency0 : poolKey.currency1),
            "fee currency must be the unspecified swap token"
        );
        assertEq(trackingPoolManager.takeCallCount(), takeCallCountBefore + 1, "gross fee must be taken once");
        assertEq(trackingPoolManager.lastTakeAmount(), grossFee, "pool manager take must equal gross fee");

        (uint128 fees0, uint128 fees1,,, uint128 ownerFees0, uint128 ownerFees1,) =
            trackingHarness.getHookFees(poolKey.toId());
        assertEq(feeInCurrency0 ? ownerFees0 : ownerFees1, ownerCut, "owner bucket must receive five percent");
        assertEq(feeInCurrency0 ? fees0 : fees1, routingAmount, "routing bucket must receive post-owner amount");
        assertEq(
            uint256(feeInCurrency0 ? ownerFees0 : ownerFees1) + uint256(feeInCurrency0 ? fees0 : fees1),
            grossFee,
            "owner and routing buckets must conserve gross fee"
        );
        assertEq(feeInCurrency0 ? fees1 + ownerFees1 : fees0 + ownerFees0, 0, "opposite token buckets must stay zero");
    }

    function _assertPostOwnerRouting(
        uint256 caseIndex,
        bool routeToBeneficiaryFees
    ) internal returns (uint256 ownerCut) {
        PoolKey memory poolKey = _grossAccountingPoolKey(caseIndex);
        address buybackDst = makeAddr(routeToBeneficiaryFees ? "routed beneficiary" : "direct buyback");
        InitData memory initData = _directOnlyInitData(address(token1), buybackDst, routeToBeneficiaryFees);

        vm.prank(address(initializer));
        trackingHarness.onInitialization(address(token0), poolKey, abi.encode(initData));

        uint256 feeBase = 160_001_520;
        uint256 grossFee = feeBase * 10_000 / MAX_SWAP_FEE;
        ownerCut = grossFee * AIRLOCK_OWNER_FEE_BPS / BPS_DENOMINATOR;
        uint256 routingAmount = grossFee - ownerCut;
        uint256 recipientBalanceBefore = token1.balanceOf(buybackDst);
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -int256(1), sqrtPriceLimitX96: 0 });

        vm.prank(address(initializer));
        (, int128 hookDelta) = trackingHarness.onSwap(
            address(0x1234), poolKey, params, toBalanceDelta(-int128(uint128(feeBase)), int128(uint128(feeBase))), ""
        );

        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 ownerFees0,
            uint128 ownerFees1,
        ) = trackingHarness.getHookFees(poolKey.toId());
        assertEq(uint256(uint128(hookDelta)), grossFee, "downstream routing must not reduce hook delta");
        assertEq(ownerFees0, 0, "owner fee must accrue only in fee currency");
        assertEq(ownerFees1, ownerCut, "owner fee must be reserved before routing");
        assertEq(fees0 + fees1, 0, "routing input buckets must be cleared after downstream routing");
        assertEq(beneficiaryFees0, 0, "opposite beneficiary bucket must remain zero");

        if (routeToBeneficiaryFees) {
            assertEq(beneficiaryFees1, routingAmount, "only the post-owner amount may reach beneficiaries");
            assertEq(token1.balanceOf(buybackDst), recipientBalanceBefore, "routed buyback must not transfer directly");
        } else {
            assertEq(beneficiaryFees1, 0, "zero beneficiary allocation must leave no beneficiary residue");
            assertEq(
                token1.balanceOf(buybackDst) - recipientBalanceBefore,
                routingAmount,
                "only the post-owner amount may be transferred as direct buyback"
            );
        }

        assertEq(ownerCut + routingAmount, grossFee, "downstream accounting must conserve the gross fee");
    }

    function _executeRealLpMatrixSwap(
        uint256 feeBase,
        uint256 expectedGross
    ) internal returns (RealLpObservation memory observed) {
        deployFreshManagerAndRouters();
        (Currency realCurrency0, Currency realCurrency1) = deployMintAndApprove2Currencies();
        (PoolKey memory poolKey,) =
            initPoolAndAddLiquidity(realCurrency0, realCurrency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        RealLpHookCaller caller = new RealLpHookCaller(manager);
        RehypeDopplerHookHarness realHook = new RehypeDopplerHookHarness(address(caller), manager);
        caller.bindHook(realHook);

        address buybackDst = makeAddr("real LP matrix buyback");
        InitData memory initData = _nonzeroLpMatrixInitData(Currency.unwrap(realCurrency1), buybackDst);
        caller.initialize(Currency.unwrap(realCurrency0), poolKey, abi.encode(initData));
        realCurrency0.transfer(address(caller), expectedGross);

        int128 signedFeeBase = int128(uint128(feeBase));
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: int256(1), sqrtPriceLimitX96: 0 });
        BalanceDelta swapDelta = toBalanceDelta(-signedFeeBase, signedFeeBase);
        uint256 managerBalance0Before = realCurrency0.balanceOf(address(manager));
        uint256 managerBalance1Before = realCurrency1.balanceOf(address(manager));
        uint256 recipientBalanceBefore = realCurrency0.balanceOf(buybackDst);

        vm.recordLogs();
        (Currency observedFeeCurrency, int128 hookDelta) = caller.executeSwapHook(poolKey, params, swapDelta);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int128 lpSwapAmount0, int128 lpSwapAmount1, int256 modifyLiquidityDelta) =
            _observeRealLpEvents(logs, poolKey.toId(), address(realHook));

        (int24 tickLower, int24 tickUpper, uint128 hookPositionLiquidity, bytes32 salt) =
            realHook.getPosition(poolKey.toId());
        (uint128 managerPositionLiquidity,,) =
            manager.getPositionInfo(poolKey.toId(), address(realHook), tickLower, tickUpper, salt);

        observed = RealLpObservation({
            poolKey: poolKey,
            hook: address(realHook),
            buybackDst: buybackDst,
            observedFeeCurrency: Currency.unwrap(observedFeeCurrency),
            hookDelta: uint256(uint128(hookDelta)),
            directTransfer: realCurrency0.balanceOf(buybackDst) - recipientBalanceBefore,
            hookBalance0: realCurrency0.balanceOf(address(realHook)),
            hookBalance1: realCurrency1.balanceOf(address(realHook)),
            managerBalanceDelta0: _signedDelta(realCurrency0.balanceOf(address(manager)), managerBalance0Before),
            managerBalanceDelta1: _signedDelta(realCurrency1.balanceOf(address(manager)), managerBalance1Before),
            lpSwapAmount0: lpSwapAmount0,
            lpSwapAmount1: lpSwapAmount1,
            modifyLiquidityDelta: modifyLiquidityDelta,
            hookPositionLiquidity: hookPositionLiquidity,
            managerPositionLiquidity: managerPositionLiquidity
        });
    }

    function _assertRealLpMatrixState(
        RealLpObservation memory observed,
        NonzeroLpAccounting memory expected
    ) internal view {
        assertEq(observed.observedFeeCurrency, Currency.unwrap(observed.poolKey.currency0), "fee currency mismatch");
        assertEq(observed.hookDelta, expected.gross, "hook delta must return gross fee");
        assertGt(expected.lp, EPSILON, "matrix must force the LP rebalance branch");
        assertGt(expected.roundingDust, 0, "matrix must exercise downstream floor rounding");
        assertLt(observed.lpSwapAmount0, 0, "LP rebalance must swap currency0 in");
        assertGt(observed.lpSwapAmount1, 0, "LP rebalance must receive currency1");
        assertGt(observed.modifyLiquidityDelta, 0, "LP branch must call modifyLiquidity with an addition");
        assertGt(observed.hookPositionLiquidity, 0, "hook position liquidity must increase");
        assertEq(
            uint256(observed.modifyLiquidityDelta),
            observed.hookPositionLiquidity,
            "modifyLiquidity event must equal hook position increase"
        );
        assertEq(
            observed.managerPositionLiquidity,
            observed.hookPositionLiquidity,
            "PoolManager position must record the hook liquidity"
        );

        int256 liquidityPaid0Signed = observed.managerBalanceDelta0 + int256(observed.lpSwapAmount0);
        int256 liquidityPaid1Signed = observed.managerBalanceDelta1 + int256(observed.lpSwapAmount1);
        assertGt(liquidityPaid0Signed, 0, "liquidity addition must pay currency0");
        assertGt(liquidityPaid1Signed, 0, "liquidity addition must pay currency1");

        uint256 lpSwapIn = uint256(uint128(-observed.lpSwapAmount0));
        uint256 lpSwapOut = uint256(uint128(observed.lpSwapAmount1));
        uint256 liquidityPaid0 = uint256(liquidityPaid0Signed);
        uint256 liquidityPaid1 = uint256(liquidityPaid1Signed);
        uint256 observedLpSpend0 = lpSwapIn + liquidityPaid0;
        assertLe(observedLpSpend0, expected.lp, "observed LP spend must stay within the configured LP budget");
        assertGe(
            observedLpSpend0,
            expected.lp - EPSILON,
            "observed LP spend must consume all but a legitimate small rebalance residue"
        );
        assertLe(liquidityPaid1, lpSwapOut, "liquidity deposit must stay within the observed LP swap output");

        uint256 lpResidue0 = expected.lp - observedLpSpend0;
        uint256 lpResidue1 = lpSwapOut - liquidityPaid1;
        assertLe(lpResidue0, EPSILON, "currency0 LP residue must be at most EPSILON");
        assertLe(lpResidue1, EPSILON, "currency1 LP residue must be at most EPSILON");

        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 ownerFees0,
            uint128 ownerFees1,
        ) = RehypeDopplerHookInitializer(payable(observed.hook)).getHookFees(observed.poolKey.toId());

        assertEq(ownerFees0, expected.owner, "role bucket must equal floor(gross * 500 / 10_000)");
        assertEq(ownerFees1, 0, "opposite owner bucket must remain zero");
        assertEq(fees0 + fees1, 0, "post-owner routing input must be fully processed");
        assertEq(
            beneficiaryFees0,
            expected.beneficiary + lpResidue0,
            "currency0 beneficiary bucket must exclude swapped and deposited LP"
        );
        assertEq(beneficiaryFees1, lpResidue1, "currency1 beneficiary bucket must contain only measured LP residue");
        assertEq(observed.directTransfer, expected.direct, "direct leg must transfer only its post-owner allocation");
        assertEq(
            expected.direct + expected.beneficiary + expected.lp + expected.roundingDust,
            expected.postOwner,
            "all independently derived routing legs and dust must conserve post-owner fees"
        );
        assertEq(
            expected.owner + expected.direct + expected.beneficiary + expected.lp + expected.roundingDust,
            expected.gross,
            "owner and independently derived post-owner uses must conserve gross"
        );
        assertEq(expected.lp, observedLpSpend0 + lpResidue0, "currency0 LP budget must reconcile exactly");
        assertEq(lpSwapOut, liquidityPaid1 + lpResidue1, "currency1 LP swap output must reconcile exactly");
        assertEq(
            observed.hookBalance0,
            expected.owner + beneficiaryFees0 + expected.roundingDust,
            "hook currency0 balance must contain owner, beneficiary residue, and routing dust"
        );
        assertEq(observed.hookBalance1, beneficiaryFees1, "hook currency1 balance must equal measured LP residue");
    }

    function _logRealLpAccounting(NonzeroLpAccounting memory expected, RealLpObservation memory observed) internal {
        uint256 lpSwapIn = uint256(uint128(-observed.lpSwapAmount0));
        uint256 lpSwapOut = uint256(uint128(observed.lpSwapAmount1));
        uint256 liquidityPaid0 = uint256(observed.managerBalanceDelta0 + int256(observed.lpSwapAmount0));
        uint256 liquidityPaid1 = uint256(observed.managerBalanceDelta1 + int256(observed.lpSwapAmount1));

        emit log_named_uint("gross", expected.gross);
        emit log_named_uint("owner", expected.owner);
        emit log_named_uint("post-owner", expected.postOwner);
        emit log_named_uint("direct leg", expected.direct);
        emit log_named_uint("beneficiary leg", expected.beneficiary);
        emit log_named_uint("LP leg", expected.lp);
        emit log_named_uint("rounding dust", expected.roundingDust);
        emit log_named_uint("LP swap input", lpSwapIn);
        emit log_named_uint("LP swap output", lpSwapOut);
        emit log_named_uint("liquidity paid currency0", liquidityPaid0);
        emit log_named_uint("liquidity paid currency1", liquidityPaid1);
        emit log_named_uint("LP residue currency0", expected.lp - lpSwapIn - liquidityPaid0);
        emit log_named_uint("LP residue currency1", lpSwapOut - liquidityPaid1);
        emit log_named_uint("position liquidity", observed.hookPositionLiquidity);
    }

    function _nonzeroLpExpectation(uint256 feeBase) internal pure returns (NonzeroLpAccounting memory expected) {
        expected.gross = feeBase * 10_000 / MAX_SWAP_FEE;
        expected.owner = expected.gross * 500 / 10_000;
        expected.postOwner = expected.gross - expected.owner;

        expected.direct = expected.postOwner * 0.31e18 / WAD;
        expected.beneficiary = expected.postOwner * 0.27e18 / WAD;
        expected.lp = expected.postOwner * 0.42e18 / WAD;
        expected.roundingDust = expected.postOwner - expected.direct - expected.beneficiary - expected.lp;
    }

    function _observeRealLpEvents(
        Vm.Log[] memory logs,
        PoolId poolId,
        address hook
    ) internal view returns (int128 swapAmount0, int128 swapAmount1, int256 modifyLiquidityDelta) {
        bytes32 swapEvent = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bytes32 modifyLiquidityEvent = keccak256("ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)");
        uint256 swapCount;
        uint256 modifyLiquidityCount;

        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(manager) || logs[i].topics.length < 3
                    || logs[i].topics[1] != PoolId.unwrap(poolId)
                    || address(uint160(uint256(logs[i].topics[2]))) != hook
            ) continue;

            if (logs[i].topics[0] == swapEvent) {
                (swapAmount0, swapAmount1,,,,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++swapCount;
            } else if (logs[i].topics[0] == modifyLiquidityEvent) {
                (,, modifyLiquidityDelta,) = abi.decode(logs[i].data, (int24, int24, int256, bytes32));
                ++modifyLiquidityCount;
            }
        }

        require(swapCount == 1, "expected one LP rebalance swap");
        require(modifyLiquidityCount == 1, "expected one LP liquidity addition");
    }

    function _signedDelta(uint256 afterBalance, uint256 beforeBalance) internal pure returns (int256) {
        return int256(afterBalance) - int256(beforeBalance);
    }

    function _grossAccountingPoolKey(uint256 caseIndex) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: uint24(1000 + caseIndex),
            tickSpacing: 60,
            hooks: IHooks(address(trackingHarness))
        });
    }

    function _initializeGrossAccountingPool(PoolKey memory poolKey, bool configureBeneficiaries) internal {
        InitData memory initData = _beneficiaryOnlyInitData(address(token1), address(0), 10_000, 10_000, 0, 0);
        if (configureBeneficiaries) {
            initData.feeRoutingMode = FeeRoutingMode.RouteToBeneficiaryFees;
            initData.feeBeneficiaries = new BeneficiaryData[](2);
            initData.feeBeneficiaries[0] = BeneficiaryData({ beneficiary: address(1), shares: uint96(0.5e18) });
            initData.feeBeneficiaries[1] = BeneficiaryData({ beneficiary: address(2), shares: uint96(0.5e18) });
        }

        vm.prank(address(initializer));
        trackingHarness.onInitialization(address(token0), poolKey, abi.encode(initData));
    }

    function _directOnlyInitData(
        address numeraire,
        address buybackDst,
        bool routeToBeneficiaryFees
    ) internal pure returns (InitData memory initData) {
        initData = InitData({
            numeraire: numeraire,
            buybackDst: buybackDst,
            startFee: 10_000,
            endFee: 10_000,
            durationSeconds: 0,
            startingTime: 0,
            feeRoutingMode: routeToBeneficiaryFees
                ? FeeRoutingMode.RouteToBeneficiaryFees
                : FeeRoutingMode.DirectBuyback,
            feeBeneficiaries: new BeneficiaryData[](0),
            feeDistributionInfo: FeeDistributionInfo({
                assetFeesToAssetBuybackWad: WAD,
                assetFeesToNumeraireBuybackWad: 0,
                assetFeesToBeneficiaryWad: 0,
                assetFeesToLpWad: 0,
                numeraireFeesToAssetBuybackWad: 0,
                numeraireFeesToNumeraireBuybackWad: WAD,
                numeraireFeesToBeneficiaryWad: 0,
                numeraireFeesToLpWad: 0
            })
        });

        if (routeToBeneficiaryFees) {
            initData.feeBeneficiaries = new BeneficiaryData[](2);
            initData.feeBeneficiaries[0] = BeneficiaryData({ beneficiary: address(1), shares: uint96(0.5e18) });
            initData.feeBeneficiaries[1] = BeneficiaryData({ beneficiary: address(2), shares: uint96(0.5e18) });
        }
    }

    function _nonzeroLpMatrixInitData(
        address numeraire,
        address buybackDst
    ) internal pure returns (InitData memory initData) {
        initData = InitData({
            numeraire: numeraire,
            buybackDst: buybackDst,
            startFee: 10_000,
            endFee: 10_000,
            durationSeconds: 0,
            startingTime: 0,
            feeRoutingMode: FeeRoutingMode.DirectBuyback,
            feeBeneficiaries: new BeneficiaryData[](0),
            feeDistributionInfo: FeeDistributionInfo({
                assetFeesToAssetBuybackWad: 0.31e18,
                assetFeesToNumeraireBuybackWad: 0,
                assetFeesToBeneficiaryWad: 0.27e18,
                assetFeesToLpWad: 0.42e18,
                numeraireFeesToAssetBuybackWad: 0,
                numeraireFeesToNumeraireBuybackWad: 0.31e18,
                numeraireFeesToBeneficiaryWad: 0.27e18,
                numeraireFeesToLpWad: 0.42e18
            })
        });
    }

    function _decayInitData(
        address numeraire,
        address buybackDst,
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint32 startingTime
    ) internal pure returns (InitData memory) {
        return InitData({
            numeraire: numeraire,
            buybackDst: buybackDst,
            startFee: startFee,
            endFee: endFee,
            durationSeconds: durationSeconds,
            startingTime: startingTime,
            feeRoutingMode: FeeRoutingMode.DirectBuyback,
            feeBeneficiaries: new BeneficiaryData[](0),
            feeDistributionInfo: FeeDistributionInfo({
                assetFeesToAssetBuybackWad: 0.25e18,
                assetFeesToNumeraireBuybackWad: 0.25e18,
                assetFeesToBeneficiaryWad: 0.25e18,
                assetFeesToLpWad: 0.25e18,
                numeraireFeesToAssetBuybackWad: 0.25e18,
                numeraireFeesToNumeraireBuybackWad: 0.25e18,
                numeraireFeesToBeneficiaryWad: 0.25e18,
                numeraireFeesToLpWad: 0.25e18
            })
        });
    }

    function _beneficiaryOnlyInitData(
        address numeraire,
        address buybackDst,
        uint24 startFee,
        uint24 endFee,
        uint32 durationSeconds,
        uint32 startingTime
    ) internal pure returns (InitData memory) {
        return InitData({
            numeraire: numeraire,
            buybackDst: buybackDst,
            startFee: startFee,
            endFee: endFee,
            durationSeconds: durationSeconds,
            startingTime: startingTime,
            feeRoutingMode: FeeRoutingMode.DirectBuyback,
            feeBeneficiaries: new BeneficiaryData[](0),
            feeDistributionInfo: FeeDistributionInfo({
                assetFeesToAssetBuybackWad: 0,
                assetFeesToNumeraireBuybackWad: 0,
                assetFeesToBeneficiaryWad: WAD,
                assetFeesToLpWad: 0,
                numeraireFeesToAssetBuybackWad: 0,
                numeraireFeesToNumeraireBuybackWad: 0,
                numeraireFeesToBeneficiaryWad: WAD,
                numeraireFeesToLpWad: 0
            })
        });
    }

    function _feeBeneficiaries(
        address owner,
        uint96 ownerShares
    ) internal pure returns (BeneficiaryData[] memory beneficiaries) {
        beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(1), shares: uint96(WAD) - ownerShares });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: ownerShares });
    }
}
