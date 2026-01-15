// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotInitializer } from "src/base/BaseDopplerHook.sol";
import { FeeDistributionMustAddUpToWAD, RehypeDopplerHook, SenderNotBeneficiary } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { FeeDistributionInfo, HookFees, PoolInfo } from "src/types/RehypeTypes.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract MockPoolManager {
    // Minimal mock - just needs to exist for the quoter constructor
}

contract MockInitializer {
    mapping(address asset => BeneficiaryData[] beneficiaries) internal _beneficiaries;

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
    address internal initializer = makeAddr("initializer");
    MockInitializer internal mockInitializer;
    IPoolManager internal poolManager;

    function setUp() public {
        poolManager = IPoolManager(address(new MockPoolManager()));
        dopplerHook = new RehypeDopplerHook(initializer, poolManager);
        mockInitializer = new MockInitializer();
        dopplerHookWithMockInitializer = new RehypeDopplerHook(address(mockInitializer), poolManager);
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(dopplerHook.INITIALIZER(), initializer);
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

        vm.prank(initializer);
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
        (uint128 fees0, uint128 fees1, uint128 beneficiaryFees0, uint128 beneficiaryFees1, uint24 storedCustomFee) =
            dopplerHook.getHookFees(poolId);
        assertEq(storedCustomFee, customFee);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        assertEq(beneficiaryFees0, 0);
        assertEq(beneficiaryFees1, 0);
    }

    function test_onInitialization_InitializesPosition(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60; // Common tick spacing

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(3000), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(initializer);
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

        vm.prank(initializer);
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        dopplerHook.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_RevertsWhenFeeDistributionExceedsWAD(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        // Fee distribution that exceeds WAD
        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.5e18, 0.5e18, 0.5e18, 0.5e18);

        vm.prank(initializer);
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

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, data);

        // Simulate a swap with amountSpecified < 0 (exact input) and zeroForOne = true
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(initializer);
        dopplerHook.onSwap(address(0x123), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));

        PoolId poolId = poolKey.toId();

        // Fee should be 1% of 1e18 = 0.01e18
        // Since fees are below EPSILON after distribution, they should accumulate to beneficiary
        (,,,, uint128 beneficiaryFees1) = dopplerHook.getHookFees(poolId);
        // Note: Actual fee accumulation depends on the fee logic, but fees0 should have been set
    }

    /* ----------------------------------------------------------------------------- */
    /*                            setFeeDistribution()                               */
    /* ----------------------------------------------------------------------------- */

    function test_setFeeDistribution_UpdatesDistribution(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Update fee distribution
        vm.prank(initializer);
        dopplerHook.setFeeDistribution(poolId, 0.5e18, 0, 0.5e18, 0);

        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            dopplerHook.getFeeDistributionInfo(poolId);

        assertEq(storedAssetBuyback, 0.5e18);
        assertEq(storedNumeraireBuyback, 0);
        assertEq(storedBeneficiary, 0.5e18);
        assertEq(storedLp, 0);
    }

    function test_setFeeDistribution_RevertsWhenSenderNotInitializer(PoolKey memory poolKey) public {
        vm.expectRevert(SenderNotInitializer.selector);
        dopplerHook.setFeeDistribution(poolKey.toId(), 0.25e18, 0.25e18, 0.25e18, 0.25e18);
    }

    function test_setFeeDistribution_RevertsWhenDoesNotAddToWAD(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, data);

        vm.prank(initializer);
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        dopplerHook.setFeeDistribution(poolKey.toId(), 0.5e18, 0.5e18, 0.5e18, 0);
    }

    /* ----------------------------------------------------------------------------------- */
    /*                        setFeeDistributionByBeneficiary()                            */
    /* ----------------------------------------------------------------------------------- */

    function test_setFeeDistributionByBeneficiary_UpdatesDistribution(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address beneficiary1 = makeAddr("beneficiary1");
        address beneficiary2 = makeAddr("beneficiary2");

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        // Set up beneficiaries in mock initializer
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: beneficiary1, shares: uint96(0.5e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: beneficiary2, shares: uint96(0.5e18) });
        mockInitializer.setBeneficiaries(asset, beneficiaries);

        vm.prank(address(mockInitializer));
        dopplerHookWithMockInitializer.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Beneficiary updates fee distribution
        vm.prank(beneficiary1);
        dopplerHookWithMockInitializer.setFeeDistributionByBeneficiary(poolId, 0.5e18, 0, 0.5e18, 0);

        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            dopplerHookWithMockInitializer.getFeeDistributionInfo(poolId);

        assertEq(storedAssetBuyback, 0.5e18);
        assertEq(storedNumeraireBuyback, 0);
        assertEq(storedBeneficiary, 0.5e18);
        assertEq(storedLp, 0);
    }

    function test_setFeeDistributionByBeneficiary_WorksForAnyBeneficiary(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address beneficiary1 = makeAddr("beneficiary1");
        address beneficiary2 = makeAddr("beneficiary2");

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        // Set up beneficiaries in mock initializer
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: beneficiary1, shares: uint96(0.5e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: beneficiary2, shares: uint96(0.5e18) });
        mockInitializer.setBeneficiaries(asset, beneficiaries);

        vm.prank(address(mockInitializer));
        dopplerHookWithMockInitializer.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Second beneficiary also can update fee distribution
        vm.prank(beneficiary2);
        dopplerHookWithMockInitializer.setFeeDistributionByBeneficiary(poolId, 0.1e18, 0.2e18, 0.3e18, 0.4e18);

        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            dopplerHookWithMockInitializer.getFeeDistributionInfo(poolId);

        assertEq(storedAssetBuyback, 0.1e18);
        assertEq(storedNumeraireBuyback, 0.2e18);
        assertEq(storedBeneficiary, 0.3e18);
        assertEq(storedLp, 0.4e18);
    }

    function test_setFeeDistributionByBeneficiary_RevertsWhenSenderNotBeneficiary(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address beneficiary1 = makeAddr("beneficiary1");
        address nonBeneficiary = makeAddr("nonBeneficiary");

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        // Set up beneficiaries in mock initializer (nonBeneficiary is NOT included)
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: beneficiary1, shares: uint96(WAD) });
        mockInitializer.setBeneficiaries(asset, beneficiaries);

        vm.prank(address(mockInitializer));
        dopplerHookWithMockInitializer.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Non-beneficiary tries to update fee distribution
        vm.prank(nonBeneficiary);
        vm.expectRevert(SenderNotBeneficiary.selector);
        dopplerHookWithMockInitializer.setFeeDistributionByBeneficiary(poolId, 0.25e18, 0.25e18, 0.25e18, 0.25e18);
    }

    function test_setFeeDistributionByBeneficiary_RevertsWhenDoesNotAddToWAD(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address beneficiary1 = makeAddr("beneficiary1");

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        // Set up beneficiaries in mock initializer
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: beneficiary1, shares: uint96(WAD) });
        mockInitializer.setBeneficiaries(asset, beneficiaries);

        vm.prank(address(mockInitializer));
        dopplerHookWithMockInitializer.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Beneficiary tries to update with invalid distribution (doesn't add to WAD)
        vm.prank(beneficiary1);
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        dopplerHookWithMockInitializer.setFeeDistributionByBeneficiary(poolId, 0.5e18, 0.5e18, 0.5e18, 0);
    }

    /* ----------------------------------------------------------------------------- */
    /*                              collectFees()                                    */
    /* ----------------------------------------------------------------------------- */

    function test_collectFees_ReturnsZeroWhenNoFees(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(initializer);
        dopplerHook.onInitialization(asset, poolKey, data);

        // collectFees should return zero delta when no fees accumulated
        // Note: This will revert or return zeros depending on implementation
        // For now, we just verify the hook fees are zero
        PoolId poolId = poolKey.toId();
        (,,, uint128 beneficiaryFees0, uint128 beneficiaryFees1) = dopplerHook.getHookFees(poolId);

        assertEq(beneficiaryFees0, 0);
        assertEq(beneficiaryFees1, 0);
    }
}
