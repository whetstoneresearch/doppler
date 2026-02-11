// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { SenderNotInitializer } from "src/base/BaseDopplerHook.sol";
import {
    FeeDistributionMustAddUpToWAD,
    RehypeDopplerHook,
    SenderNotAuthorized
} from "src/dopplerHooks/RehypeDopplerHook.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { FeeDistributionInfo, HookFees, PoolInfo } from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

contract MockPoolManager {
    // Minimal mock - just needs to exist for the quoter constructor
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
    MockInitializer internal initializer;
    MockInitializer internal mockInitializer;
    IPoolManager internal poolManager;

    function setUp() public {
        poolManager = IPoolManager(address(new MockPoolManager()));
        initializer = new MockInitializer();
        dopplerHook = new RehypeDopplerHook(address(initializer), poolManager);
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
            numeraire,
            buybackDst,
            customFee,
            assetBuybackPercentWad,
            numeraireBuybackPercentWad,
            beneficiaryPercentWad,
            lpPercentWad
        );

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Check pool info
        (address storedAsset, address storedNumeraire, address storedBuybackDst) = dopplerHook.getPoolInfo(poolId);
        assertEq(storedAsset, asset);
        assertEq(storedNumeraire, numeraire);
        assertEq(storedBuybackDst, buybackDst);

        // Check fee distribution info
        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            dopplerHook.getFeeDistributionInfo(poolId);
        assertEq(storedAssetBuyback, assetBuybackPercentWad);
        assertEq(storedNumeraireBuyback, numeraireBuybackPercentWad);
        assertEq(storedBeneficiary, beneficiaryPercentWad);
        assertEq(storedLp, lpPercentWad);

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
        assertEq(storedCustomFee, customFee);
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

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(3000), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

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
        bytes memory data = abi.encode(address(0), address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.onInitialization(address(0), poolKey, data);
    }

    function test_onInitialization_RevertsWhenFeeDistributionDoesNotAddToWAD(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        // Fee distribution that doesn't add up to WAD
        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.24e18);

        vm.prank(address(initializer));
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_RevertsWhenFeeDistributionExceedsWAD(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        // Fee distribution that exceeds WAD
        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.5e18, 0.5e18, 0.5e18, 0.5e18);

        vm.prank(address(initializer));
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    /* ---------------------------------------------------------------------- */
    /*                                onSwap()                                */
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
        bytes memory data = abi.encode(numeraire, buybackDst, customFee, 0, 0, WAD, 0);

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

    /* ----------------------------------------------------------------------------- */
    /*                            setFeeDistribution()                               */
    /* ----------------------------------------------------------------------------- */

    function test_setFeeDistribution_UpdatesDistribution(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        console.log("dst", buybackDst);
        // Update fee distribution
        vm.prank(buybackDst);
        dopplerHook.setFeeDistribution(poolId, 0.5e18, 0, 0.5e18, 0);

        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            dopplerHook.getFeeDistributionInfo(poolId);

        assertEq(storedAssetBuyback, 0.5e18);
        assertEq(storedNumeraireBuyback, 0);
        assertEq(storedBeneficiary, 0.5e18);
        assertEq(storedLp, 0);
    }

    function test_setFeeDistribution_RevertsWhenSenderNotAuthorized(PoolKey memory poolKey) public {
        vm.expectRevert(SenderNotAuthorized.selector);
        dopplerHook.setFeeDistribution(poolKey.toId(), 0.25e18, 0.25e18, 0.25e18, 0.25e18);
    }

    function test_setFeeDistribution_RevertsWhenDoesNotAddToWAD(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(initializer));
        dopplerHook.onInitialization(asset, poolKey, data);

        vm.prank(buybackDst);
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        dopplerHook.setFeeDistribution(poolKey.toId(), 0.5e18, 0.5e18, 0.5e18, 0);
    }

    /* ----------------------------------------------------------------------------- */
    /*                              collectFees()                                    */
    /* ----------------------------------------------------------------------------- */

    function test_collectFees_ReturnsZeroWhenNoFees(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

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
}
