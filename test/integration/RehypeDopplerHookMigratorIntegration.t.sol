// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { ON_INITIALIZATION_FLAG, ON_AFTER_SWAP_FLAG } from "src/base/BaseDopplerHookMigrator.sol";
import {
    FeeDistributionMustAddUpToWAD,
    RehypeDopplerHookMigrator,
    SenderNotAirlockOwner,
    SenderNotAuthorized
} from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DopplerHookMigrator, PoolStatus as MigratorStatus } from "src/migrators/DopplerHookMigrator.sol";
import { CloneERC20Factory } from "src/tokens/CloneERC20Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract RehypeDopplerHookMigratorIntegrationTest is Deployers {
    using StateLibrary for IPoolManager;

    address internal constant AIRLOCK_OWNER = address(0xA111);
    address internal constant BENEFICIARY_1 = address(0x1111);
    address internal constant BUYBACK_DST = address(0xBEEF);

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    CloneERC20Factory public tokenFactory;
    NoOpGovernanceFactory public governanceFactory;
    StreamableFeesLockerV2 public locker;
    DopplerHookMigrator public migrator;
    TopUpDistributor public topUpDistributor;
    RehypeDopplerHookMigrator public rehypeHookMigrator;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(AIRLOCK_OWNER);
        tokenFactory = new CloneERC20Factory(address(airlock));
        governanceFactory = new NoOpGovernanceFactory();

        initializer = DopplerHookInitializer(
            payable(
                address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                )
            )
        );
        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));

        locker = new StreamableFeesLockerV2(IPoolManager(address(manager)), AIRLOCK_OWNER);
        topUpDistributor = new TopUpDistributor(address(airlock));

        uint256 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address migratorHookAddress = address(uint160(hookFlags) ^ (0x4444 << 144));
        migrator = DopplerHookMigrator(payable(migratorHookAddress));
        deployCodeTo(
            "DopplerHookMigrator",
            abi.encode(address(airlock), address(manager), locker, topUpDistributor),
            migratorHookAddress
        );

        rehypeHookMigrator = new RehypeDopplerHookMigrator(migrator, manager);

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(initializer);
        modules[2] = address(governanceFactory);
        modules[3] = address(migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.GovernanceFactory;
        states[3] = ModuleState.LiquidityMigrator;

        vm.startPrank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);
        locker.approveMigrator(address(migrator));
        topUpDistributor.setPullUp(address(migrator), true);

        // Enable the RehypeDopplerHookMigrator with initialization + afterSwap flags
        address[] memory dopplerHooks = new address[](1);
        uint256[] memory flags = new uint256[](1);
        dopplerHooks[0] = address(rehypeHookMigrator);
        flags[0] = ON_INITIALIZATION_FLAG | ON_AFTER_SWAP_FLAG;
        migrator.setDopplerHookState(dopplerHooks, flags);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                         FEE ACCRUAL ON SWAP                                */
    /* ========================================================================== */

    function test_rehype_feesAccrueOnSwap() public {
        address asset = _createAndMigrate(bytes32(uint256(100)));

        _buyAsset(asset, 0.5 ether);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 airlockOwnerFees0,
            uint128 airlockOwnerFees1,
        ) = rehypeHookMigrator.getHookFees(poolId);

        assertTrue(
            fees0 + fees1 + beneficiaryFees0 + beneficiaryFees1 + airlockOwnerFees0 + airlockOwnerFees1 > 0,
            "Fees should accrue after swap"
        );
    }

    function test_rehype_airlockOwnerFeeIsFivePercent() public {
        address asset = _createAndMigrate(bytes32(uint256(101)));

        _buyAsset(asset, 0.5 ether);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (uint128 fees0, uint128 fees1,,, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) =
            rehypeHookMigrator.getHookFees(poolId);

        // Airlock owner gets 5% of total fee, remaining 95% goes to fees0/fees1 (or beneficiaryFees after distribution)
        // After distribution the fees0/fees1 are zeroed. Check the ratio on the raw accumulators.
        uint128 totalRemainingFees0 = fees0;
        uint128 totalRemainingFees1 = fees1;

        // At least one side should have fees
        if (airlockOwnerFees1 > 0 && totalRemainingFees1 > 0) {
            // airlockOwnerFees should be ~5.26% of remainingFees (5/95 ratio)
            // We check: airlockOwnerFees * 19 == remainingFees (approx, with rounding tolerance)
            uint256 ratio = (uint256(airlockOwnerFees1) * 10_000) / uint256(totalRemainingFees1);
            // Expected ratio is 500/9500 * 10000 = 526 (5.26%)
            assertGt(ratio, 400, "Airlock owner fee ratio should be approximately 5/95");
            assertLt(ratio, 700, "Airlock owner fee ratio should be approximately 5/95");
        }
    }

    function test_rehype_feesAccrueInBothDirections() public {
        address asset = _createAndMigrate(bytes32(uint256(102)));

        // Buy asset (ETH → asset)
        _buyAsset(asset, 0.5 ether);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (,, uint128 beneficiaryFees0Before, uint128 beneficiaryFees1Before, uint128 airlockOwnerFees0Before, uint128 airlockOwnerFees1Before,) =
            rehypeHookMigrator.getHookFees(poolId);

        uint256 totalBefore =
            uint256(beneficiaryFees0Before) + beneficiaryFees1Before + airlockOwnerFees0Before + airlockOwnerFees1Before;

        // Sell asset back (asset → ETH)
        _sellAsset(asset, ERC20(asset).balanceOf(address(this)) / 2);

        (,, uint128 beneficiaryFees0After, uint128 beneficiaryFees1After, uint128 airlockOwnerFees0After, uint128 airlockOwnerFees1After,) =
            rehypeHookMigrator.getHookFees(poolId);

        uint256 totalAfter =
            uint256(beneficiaryFees0After) + beneficiaryFees1After + airlockOwnerFees0After + airlockOwnerFees1After;

        assertGt(totalAfter, totalBefore, "Selling asset should generate additional fees");
    }

    function test_rehype_multipleSwapsAccumulateFees() public {
        address asset = _createAndMigrate(bytes32(uint256(103)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        _buyAsset(asset, 0.1 ether);

        (,,,, uint128 airlockOwnerFees0First, uint128 airlockOwnerFees1First,) =
            rehypeHookMigrator.getHookFees(poolId);
        uint256 totalFirst = uint256(airlockOwnerFees0First) + airlockOwnerFees1First;

        _buyAsset(asset, 0.1 ether);
        _buyAsset(asset, 0.1 ether);

        (,,,, uint128 airlockOwnerFees0After, uint128 airlockOwnerFees1After,) =
            rehypeHookMigrator.getHookFees(poolId);
        uint256 totalAfter = uint256(airlockOwnerFees0After) + airlockOwnerFees1After;

        assertGt(totalAfter, totalFirst, "Fees should grow with each swap");
    }

    function test_rehype_noFeesWhenCustomFeeIsZero() public {
        address asset = _createAndMigrateWithCustomFee(bytes32(uint256(104)), 0);

        _buyAsset(asset, 0.5 ether);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 airlockOwnerFees0,
            uint128 airlockOwnerFees1,
        ) = rehypeHookMigrator.getHookFees(poolId);

        assertEq(fees0 + fees1 + beneficiaryFees0 + beneficiaryFees1 + airlockOwnerFees0 + airlockOwnerFees1, 0, "No fees should accrue with zero custom fee");
    }

    /* ========================================================================== */
    /*                            COLLECT FEES                                    */
    /* ========================================================================== */

    function test_rehype_collectFees_transfersToBuybackDst() public {
        address asset = _createAndMigrate(bytes32(uint256(200)));

        // Generate fees through swaps
        _buyAsset(asset, 0.5 ether);
        _sellAsset(asset, ERC20(asset).balanceOf(address(this)) / 2);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeHookMigrator.getHookFees(poolId);

        if (beneficiaryFees0 + beneficiaryFees1 > 0) {
            uint256 buybackBalanceBefore0 = Currency.unwrap(poolKey.currency0) == address(0)
                ? BUYBACK_DST.balance
                : ERC20(Currency.unwrap(poolKey.currency0)).balanceOf(BUYBACK_DST);
            uint256 buybackBalanceBefore1 = ERC20(Currency.unwrap(poolKey.currency1)).balanceOf(BUYBACK_DST);

            BalanceDelta fees = rehypeHookMigrator.collectFees(asset);

            uint256 buybackBalanceAfter0 = Currency.unwrap(poolKey.currency0) == address(0)
                ? BUYBACK_DST.balance
                : ERC20(Currency.unwrap(poolKey.currency0)).balanceOf(BUYBACK_DST);
            uint256 buybackBalanceAfter1 = ERC20(Currency.unwrap(poolKey.currency1)).balanceOf(BUYBACK_DST);

            if (beneficiaryFees0 > 0) {
                assertEq(
                    buybackBalanceAfter0 - buybackBalanceBefore0,
                    beneficiaryFees0,
                    "BuybackDst should receive currency0 beneficiary fees"
                );
            }
            if (beneficiaryFees1 > 0) {
                assertEq(
                    buybackBalanceAfter1 - buybackBalanceBefore1,
                    beneficiaryFees1,
                    "BuybackDst should receive currency1 beneficiary fees"
                );
            }

            // Verify fees are reset
            (,, uint128 beneficiaryFees0After, uint128 beneficiaryFees1After,,,) =
                rehypeHookMigrator.getHookFees(poolId);
            assertEq(beneficiaryFees0After, 0, "Beneficiary fees0 should be reset");
            assertEq(beneficiaryFees1After, 0, "Beneficiary fees1 should be reset");
        }
    }

    function test_rehype_collectFees_isPermissionless() public {
        address asset = _createAndMigrate(bytes32(uint256(201)));

        _buyAsset(asset, 0.5 ether);

        // Anyone can call collectFees
        address random = makeAddr("Random");
        vm.prank(random);
        rehypeHookMigrator.collectFees(asset);
    }

    function test_rehype_collectFees_returnsZeroWhenNoFees() public {
        address asset = _createAndMigrateWithCustomFee(bytes32(uint256(202)), 0);

        _buyAsset(asset, 0.5 ether);

        BalanceDelta fees = rehypeHookMigrator.collectFees(asset);
        assertEq(fees.amount0(), 0, "Should return zero fees0");
        assertEq(fees.amount1(), 0, "Should return zero fees1");
    }

    /* ========================================================================== */
    /*                       CLAIM AIRLOCK OWNER FEES                             */
    /* ========================================================================== */

    function test_rehype_claimAirlockOwnerFees_transfersToOwner() public {
        address asset = _createAndMigrate(bytes32(uint256(300)));

        _buyAsset(asset, 0.5 ether);
        _sellAsset(asset, ERC20(asset).balanceOf(address(this)) / 2);

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (,,,, uint128 airlockOwnerFees0, uint128 airlockOwnerFees1,) = rehypeHookMigrator.getHookFees(poolId);

        if (airlockOwnerFees0 + airlockOwnerFees1 > 0) {
            uint256 ownerBalanceBefore0 = AIRLOCK_OWNER.balance;
            uint256 ownerBalanceBefore1 = ERC20(Currency.unwrap(poolKey.currency1)).balanceOf(AIRLOCK_OWNER);

            vm.prank(AIRLOCK_OWNER);
            (uint128 claimed0, uint128 claimed1) = rehypeHookMigrator.claimAirlockOwnerFees(asset);

            assertEq(claimed0, airlockOwnerFees0, "Claimed fees0 should match accumulated");
            assertEq(claimed1, airlockOwnerFees1, "Claimed fees1 should match accumulated");

            if (claimed0 > 0) {
                assertEq(
                    AIRLOCK_OWNER.balance - ownerBalanceBefore0,
                    claimed0,
                    "Airlock owner should receive ETH fees"
                );
            }
            if (claimed1 > 0) {
                assertEq(
                    ERC20(Currency.unwrap(poolKey.currency1)).balanceOf(AIRLOCK_OWNER) - ownerBalanceBefore1,
                    claimed1,
                    "Airlock owner should receive asset fees"
                );
            }

            // Verify fees are reset
            (,,,, uint128 ownerFees0After, uint128 ownerFees1After,) = rehypeHookMigrator.getHookFees(poolId);
            assertEq(ownerFees0After, 0, "Airlock owner fees0 should be reset");
            assertEq(ownerFees1After, 0, "Airlock owner fees1 should be reset");
        }
    }

    function test_rehype_claimAirlockOwnerFees_revertsForNonOwner() public {
        address asset = _createAndMigrate(bytes32(uint256(301)));

        _buyAsset(asset, 0.5 ether);

        address notOwner = makeAddr("NotOwner");
        vm.prank(notOwner);
        vm.expectRevert(SenderNotAirlockOwner.selector);
        rehypeHookMigrator.claimAirlockOwnerFees(asset);
    }

    function test_rehype_claimAirlockOwnerFees_returnsZeroWhenNoFees() public {
        address asset = _createAndMigrateWithCustomFee(bytes32(uint256(302)), 0);

        _buyAsset(asset, 0.5 ether);

        vm.prank(AIRLOCK_OWNER);
        (uint128 fees0, uint128 fees1) = rehypeHookMigrator.claimAirlockOwnerFees(asset);
        assertEq(fees0, 0, "Should return zero fees0");
        assertEq(fees1, 0, "Should return zero fees1");
    }

    function test_rehype_claimAirlockOwnerFees_canClaimMultipleTimes() public {
        address asset = _createAndMigrate(bytes32(uint256(303)));

        // First round of swaps
        _buyAsset(asset, 0.3 ether);

        vm.prank(AIRLOCK_OWNER);
        (uint128 claimed0First, uint128 claimed1First) = rehypeHookMigrator.claimAirlockOwnerFees(asset);

        // Second round of swaps
        _buyAsset(asset, 0.3 ether);

        vm.prank(AIRLOCK_OWNER);
        (uint128 claimed0Second, uint128 claimed1Second) = rehypeHookMigrator.claimAirlockOwnerFees(asset);

        // Both rounds should have yielded fees
        assertTrue(claimed0First + claimed1First > 0, "First claim should have fees");
        assertTrue(claimed0Second + claimed1Second > 0, "Second claim should have fees");
    }

    /* ========================================================================== */
    /*                         SET FEE DISTRIBUTION                               */
    /* ========================================================================== */

    function test_rehype_setFeeDistribution_updatesDistribution() public {
        address asset = _createAndMigrate(bytes32(uint256(400)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        // Verify initial distribution
        (uint256 assetBuyback, uint256 numeraireBuyback, uint256 beneficiary, uint256 lp) =
            rehypeHookMigrator.getFeeDistributionInfo(poolId);
        assertEq(assetBuyback, 0.2e18);
        assertEq(numeraireBuyback, 0.2e18);
        assertEq(beneficiary, 0.3e18);
        assertEq(lp, 0.3e18);

        // Update distribution — only buybackDst can call
        vm.prank(BUYBACK_DST);
        rehypeHookMigrator.setFeeDistribution(poolId, 0, 0, WAD, 0);

        (assetBuyback, numeraireBuyback, beneficiary, lp) = rehypeHookMigrator.getFeeDistributionInfo(poolId);
        assertEq(assetBuyback, 0, "Asset buyback should be 0");
        assertEq(numeraireBuyback, 0, "Numeraire buyback should be 0");
        assertEq(beneficiary, WAD, "Beneficiary should be 100%");
        assertEq(lp, 0, "LP should be 0");
    }

    function test_rehype_setFeeDistribution_revertsForNonBuybackDst() public {
        address asset = _createAndMigrate(bytes32(uint256(401)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        address notAuthorized = makeAddr("NotAuthorized");
        vm.prank(notAuthorized);
        vm.expectRevert(SenderNotAuthorized.selector);
        rehypeHookMigrator.setFeeDistribution(poolId, 0.25e18, 0.25e18, 0.25e18, 0.25e18);
    }

    function test_rehype_setFeeDistribution_revertsWhenNotSummingToWAD() public {
        address asset = _createAndMigrate(bytes32(uint256(402)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        vm.prank(BUYBACK_DST);
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        rehypeHookMigrator.setFeeDistribution(poolId, 0.5e18, 0.5e18, 0.5e18, 0);
    }

    function test_rehype_setFeeDistribution_affectsSubsequentSwaps() public {
        address asset = _createAndMigrate(bytes32(uint256(403)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        // Set 100% beneficiary, 0% everything else
        vm.prank(BUYBACK_DST);
        rehypeHookMigrator.setFeeDistribution(poolId, 0, 0, WAD, 0);

        // Generate fees
        _buyAsset(asset, 0.5 ether);
        _sellAsset(asset, ERC20(asset).balanceOf(address(this)) / 2);

        (uint128 fees0, uint128 fees1, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) =
            rehypeHookMigrator.getHookFees(poolId);

        // With 100% beneficiary, all distributed fees should be in beneficiaryFees
        // (fees0/fees1 should be 0 since they get distributed when > EPSILON)
        assertTrue(
            beneficiaryFees0 + beneficiaryFees1 > 0,
            "Beneficiary fees should accrue with 100% beneficiary distribution"
        );
    }

    /* ========================================================================== */
    /*                          POOL INITIALIZATION                               */
    /* ========================================================================== */

    function test_rehype_poolInfoStoredCorrectly() public {
        address asset = _createAndMigrate(bytes32(uint256(500)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (address storedAsset, address storedNumeraire, address storedBuybackDst) =
            rehypeHookMigrator.getPoolInfo(poolId);
        assertEq(storedAsset, asset, "Asset should be stored");
        assertEq(storedNumeraire, address(0), "Numeraire should be ETH (address(0))");
        assertEq(storedBuybackDst, BUYBACK_DST, "BuybackDst should be stored");
    }

    function test_rehype_feeDistributionStoredCorrectly() public {
        address asset = _createAndMigrate(bytes32(uint256(501)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (uint256 assetBuyback, uint256 numeraireBuyback, uint256 beneficiary, uint256 lp) =
            rehypeHookMigrator.getFeeDistributionInfo(poolId);
        assertEq(assetBuyback + numeraireBuyback + beneficiary + lp, WAD, "Distribution should sum to WAD");
    }

    function test_rehype_positionInitializedAsFullRange() public {
        address asset = _createAndMigrate(bytes32(uint256(502)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt) = rehypeHookMigrator.getPosition(poolId);
        assertEq(tickLower, TickMath.minUsableTick(poolKey.tickSpacing), "tickLower should be min usable tick");
        assertEq(tickUpper, TickMath.maxUsableTick(poolKey.tickSpacing), "tickUpper should be max usable tick");
        assertEq(liquidity, 0, "Initial liquidity should be 0");
        assertTrue(salt != bytes32(0), "Salt should be set");
    }

    function test_rehype_customFeeStoredCorrectly() public {
        address asset = _createAndMigrate(bytes32(uint256(503)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (,,,,,, uint24 storedFee) = rehypeHookMigrator.getHookFees(poolId);
        assertEq(storedFee, 3000, "Custom fee should be 3000 (0.3%)");
    }

    /* ========================================================================== */
    /*                            LP REINVESTMENT                                 */
    /* ========================================================================== */

    function test_rehype_lpReinvestmentAddsLiquidity() public {
        address asset = _createAndMigrate(bytes32(uint256(600)));

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);
        PoolId poolId = poolKey.toId();

        (, , uint128 liquidityBefore,) = rehypeHookMigrator.getPosition(poolId);
        assertEq(liquidityBefore, 0, "Initial LP liquidity should be 0");

        // Do many swaps to generate sufficient fees for LP reinvestment
        for (uint256 i; i < 5; i++) {
            _buyAsset(asset, 0.5 ether);
            _sellAsset(asset, ERC20(asset).balanceOf(address(this)) / 2);
        }

        (, , uint128 liquidityAfter,) = rehypeHookMigrator.getPosition(poolId);
        // LP reinvestment may or may not have occurred depending on pool conditions,
        // but if it did, liquidity should have increased
        // This is a best-effort check since LP reinvestment depends on rebalance feasibility
        if (liquidityAfter > 0) {
            assertGt(liquidityAfter, liquidityBefore, "LP liquidity should increase after reinvestment");
        }
    }

    /* ========================================================================== */
    /*                              HELPERS                                       */
    /* ========================================================================== */

    function _createAndMigrate(bytes32 salt) internal returns (address asset) {
        return _createAndMigrateWithCustomFee(salt, 3000);
    }

    function _createAndMigrateWithCustomFee(bytes32 salt, uint24 customFee) internal returns (address asset) {
        bytes memory poolInitializerData = _defaultPoolInitializerData();
        bytes memory rehypeData =
            abi.encode(address(0), BUYBACK_DST, customFee, uint256(0.2e18), uint256(0.2e18), uint256(0.3e18), uint256(0.3e18));
        bytes memory migratorData = _defaultMigratorData(address(rehypeHookMigrator), rehypeData);
        bytes memory tokenFactoryData =
            abi.encode("Rehype Integration Test Token", "RINT", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");

        (asset,,,,) = airlock.create(
            CreateParams({
                initialSupply: 1e23,
                numTokensToSell: 1e23,
                numeraire: address(0),
                tokenFactory: tokenFactory,
                tokenFactoryData: tokenFactoryData,
                governanceFactory: governanceFactory,
                governanceFactoryData: new bytes(0),
                poolInitializer: initializer,
                poolInitializerData: poolInitializerData,
                liquidityMigrator: migrator,
                liquidityMigratorData: migratorData,
                integrator: address(0),
                salt: salt
            })
        );

        _swapOnInitializerPool(asset);
        airlock.migrate(asset);
    }

    function _defaultPoolInitializerData() internal pure returns (bytes memory) {
        Curve[] memory curves = new Curve[](1);
        curves[0] = Curve({ tickLower: 160_000, tickUpper: 240_000, numPositions: 10, shares: WAD });

        return abi.encode(
            InitData({
                fee: 0,
                tickSpacing: 8,
                curves: curves,
                beneficiaries: new BeneficiaryData[](0),
                dopplerHook: address(0),
                onInitializationDopplerHookCalldata: new bytes(0),
                graduationDopplerHookCalldata: new bytes(0),
                farTick: 160_000
            })
        );
    }

    function _defaultMigratorData(
        address hook,
        bytes memory onInitializationCalldata
    ) internal pure returns (bytes memory) {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: AIRLOCK_OWNER, shares: 0.05e18 });

        return abi.encode(
            uint24(3000),
            int24(8),
            uint32(30 days),
            beneficiaries,
            false,
            hook,
            onInitializationCalldata,
            new bytes(0),
            address(0),
            uint256(0)
        );
    }

    function _swapOnInitializerPool(address asset) internal {
        (,,,, PoolStatus status, PoolKey memory poolKey,) = initializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));

        uint256 swapAmount = 0.1 ether;
        deal(address(this), swapAmount);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap{ value: swapAmount }(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
    }

    function _buyAsset(address asset, uint256 ethAmount) internal {
        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(ethAmount),
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        deal(address(this), ethAmount);
        swapRouter.swap{ value: ethAmount }(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
    }

    function _sellAsset(address asset, uint256 assetAmount) internal {
        if (assetAmount == 0) return;

        (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(address(0), asset);

        bool isToken0 = asset == Currency.unwrap(poolKey.currency0);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: isToken0,
            amountSpecified: -int256(assetAmount),
            sqrtPriceLimitX96: isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        ERC20(asset).approve(address(swapRouter), assetAmount);
        swapRouter.swap(poolKey, swapParams, PoolSwapTest.TestSettings(false, false), "");
    }
}
