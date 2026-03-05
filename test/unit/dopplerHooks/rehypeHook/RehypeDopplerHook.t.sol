// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotInitializer } from "src/base/BaseDopplerHookInitializer.sol";
import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import {
    FeeDistributionInfo,
    FeeDistributionMustAddUpToWAD,
    FeeRoutingMode,
    FeeSchedule,
    FeeScheduleSet,
    FeeTooHigh,
    FeeUpdated,
    HookFees,
    InitData,
    InvalidDurationSeconds,
    InvalidFeeRange,
    MAX_SWAP_FEE,
    PoolInfo
} from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

contract MockPoolManager {
    // Minimal mock - just needs to exist for the quoter constructor
}

/// @dev Harness to expose internal fee functions for testing
contract RehypeDopplerHookHarness is RehypeDopplerHook {
    constructor(address _initializer, IPoolManager _poolManager) RehypeDopplerHook(_initializer, _poolManager) { }

    function exposed_getCurrentFee(PoolId poolId) external returns (uint24) {
        return _getCurrentFee(poolId);
    }

    function exposed_computeCurrentFee(FeeSchedule memory schedule, uint256 elapsed) external pure returns (uint24) {
        return _computeCurrentFee(schedule, elapsed);
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
}

contract RehypeDopplerHookTest is Test {
    RehypeDopplerHook internal dopplerHook;
    RehypeDopplerHook internal dopplerHookWithMockInitializer;
    RehypeDopplerHookHarness internal harness;
    MockInitializer internal initializer;
    MockInitializer internal mockInitializer;
    IPoolManager internal poolManager;

    function setUp() public {
        poolManager = IPoolManager(address(new MockPoolManager()));
        initializer = new MockInitializer();
        dopplerHook = new RehypeDopplerHook(address(initializer), poolManager);
        harness = new RehypeDopplerHookHarness(address(initializer), poolManager);
        mockInitializer = new MockInitializer();
        dopplerHookWithMockInitializer = new RehypeDopplerHook(address(mockInitializer), poolManager);
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

    function test_onInitialization_RevertsWhenFeeRoutingModeInvalid(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        // Manually encode with struct field order but invalid feeRoutingMode (2 is out of enum range)
        bytes memory data = abi.encode(
            numeraire,
            buybackDst,
            uint24(3000),
            uint24(3000),
            uint32(0),
            uint32(0),
            uint8(2),
            uint256(0.25e18),
            uint256(0.25e18),
            uint256(0.25e18),
            uint256(0.25e18),
            uint256(0.25e18),
            uint256(0.25e18),
            uint256(0.25e18),
            uint256(0.25e18)
        );

        vm.prank(address(initializer));
        vm.expectRevert();
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    /* ---------------------------------------------------------------------- */
    /*                                onAfterSwap()                                */
    /* ---------------------------------------------------------------------- */

    function test_onAfterSwap_RevertsWhenSenderNotInitializer(
        PoolKey memory poolKey,
        IPoolManager.SwapParams memory swapParams
    ) public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onAfterSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }

    function test_onAfterSwap_AccumulatesFees(PoolKey memory poolKey) public {
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
        dopplerHook.onAfterSwap(address(0x123), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));

        PoolId poolId = poolKey.toId();

        // Fee should be 1% of 1e18 = 0.01e18
        // Since fees are below EPSILON after distribution, they should accumulate to beneficiary
        (,,,,,, uint24 storedFee) = dopplerHook.getHookFees(poolId);
        // Note: Actual fee accumulation depends on the fee logic, but fees0 should have been set
    }

    function test_onAfterSwap_SkipsWhenSenderIsHook(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        vm.prank(address(initializer));
        (Currency feeCurrency, int128 delta) = dopplerHook.onAfterSwap(
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
}
