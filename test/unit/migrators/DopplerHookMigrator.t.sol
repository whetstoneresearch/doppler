// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Constants } from "@uniswap/v4-core/test/utils/Constants.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { Airlock } from "src/Airlock.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import {
    ON_AFTER_SWAP_FLAG,
    ON_INITIALIZATION_FLAG,
    REQUIRES_DYNAMIC_LP_FEE_FLAG
} from "src/base/BaseDopplerHookMigrator.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { InvalidSplitRecipient, SplitShareTooHigh } from "src/base/ProceedsSplitter.sol";
import { IDopplerHookMigrator } from "src/interfaces/IDopplerHookMigrator.sol";
import {
    ArrayLengthsMismatch,
    AssetData,
    DopplerHookMigrator,
    HookRequiresDynamicLPFee,
    LPFeeTooHigh,
    MAX_LP_FEE,
    PoolStatus,
    WrongPoolStatus
} from "src/migrators/DopplerHookMigrator.sol";
import {
    BeneficiaryData,
    InvalidProtocolOwnerBeneficiary,
    InvalidProtocolOwnerShares,
    InvalidShares,
    InvalidTotalShares,
    MIN_PROTOCOL_OWNER_SHARES,
    UnorderedBeneficiaries
} from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/WAD.sol";
import { generateBeneficiaries } from "test/invariant/FeesManagerInvariants.t.sol";

struct InitData {
    uint24 feeOrInitialDynamicFee;
    bool useDynamicFee;
    int24 tickSpacing;
    uint32 lockDuration;
    BeneficiaryData[] beneficiaries;
    address dopplerHookMigrator;
    bytes onInitializationCalldata;
    address proceedsRecipient;
    uint256 proceedsShare;
}

contract DopplerHookMigratorTest is Deployers {
    using StateLibrary for IPoolManager;

    // Small trick so we're making sure that the protocol owner will always be at the end of the beneficiaries array
    address PROTOCOL_OWNER = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    address PROCEEDS_RECIPIENT = makeAddr("PROCEEDS_RECIPIENT");

    Airlock public airlock;
    DopplerHookMigrator public migrator;
    StreamableFeesLockerV2 public locker;
    TopUpDistributor public topUpDistributor;

    bool isToken0;
    bool isUsingETH;
    address internal asset;
    address internal numeraire;
    InitData internal initData;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");

        airlock = new Airlock(PROTOCOL_OWNER);
        locker = new StreamableFeesLockerV2(manager, PROTOCOL_OWNER);
        topUpDistributor = new TopUpDistributor(address(airlock));

        uint160 hookFlags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address migratorAddress = address(uint160(hookFlags) ^ (0x4444 << 144));
        migrator = DopplerHookMigrator(payable(migratorAddress));
        deployCodeTo("DopplerHookMigrator", abi.encode(airlock, manager, locker, topUpDistributor), migratorAddress);

        vm.startPrank(PROTOCOL_OWNER);
        locker.approveMigrator(address(migrator));
        topUpDistributor.setPullUp(address(migrator), true);
        vm.stopPrank();
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(migrator.airlock()), address(airlock));
        assertEq(address(migrator.poolManager()), address(manager));
        assertEq(address(migrator.locker()), address(locker));
        assertEq(address(migrator.TOP_UP_DISTRIBUTOR()), address(topUpDistributor));
    }

    function test_initialize_StoresData() public {
        _generateInitData();
        _initialize();

        (
            bool isTokenZero,
            PoolKey memory poolKey,
            uint32 lockDuration,
            uint24 feeOrInitialDynamicFee,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,
            PoolStatus status
        ) = migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));

        assertEq(Currency.unwrap(poolKey.currency0), Currency.unwrap(currency0), "Currency0 is wrong");
        assertEq(Currency.unwrap(poolKey.currency1), Currency.unwrap(currency1), "Currency1 is wrong");
        assertEq(poolKey.fee, initData.feeOrInitialDynamicFee, "Fee is wrong");
        assertEq(poolKey.tickSpacing, initData.tickSpacing, "Tick spacing is wrong");
        assertEq(address(poolKey.hooks), address(migrator), "Hooks address is wrong");
        assertEq(lockDuration, initData.lockDuration, "Lock duration is wrong");
        assertEq(isTokenZero, isToken0, "Is token zero is wrong");
        assertEq(feeOrInitialDynamicFee, initData.feeOrInitialDynamicFee, "Fee or initial dynamic fee is wrong");
        assertEq(dopplerHook, initData.dopplerHookMigrator, "Doppler hook migrator is wrong");
        assertEq(onInitializationCalldata, initData.onInitializationCalldata, "On initialization calldata is wrong");
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status is wrong");
        assertEq(useDynamicFee, initData.useDynamicFee, "Use dynamic fee is wrong");
    }

    function test_initialize_RevertsIfSenderNotAirlock() public {
        _generateInitData();
        vm.expectRevert(SenderNotAirlock.selector);
        migrator.initialize(asset, numeraire, _encodeInitData());
    }

    // TODO: Abstract this using the BeneficiaryData library tests
    function test_initialize_RevertsWhenUnorderedBeneficiaries() public {
        _generateInitData();
        initData.beneficiaries[0].beneficiary = address(0);
        vm.expectRevert(abi.encodeWithSelector(UnorderedBeneficiaries.selector));
        _initialize();
    }

    // TODO: Abstract this using the BeneficiaryData library tests
    function test_initialize_RevertZeroShares() public {
        _generateInitData();
        initData.beneficiaries[0].shares = 0;
        vm.expectRevert(abi.encodeWithSelector(InvalidShares.selector));
        _initialize();
    }

    // TODO: Abstract this using the BeneficiaryData library tests
    function test_initialize_RevertIncorrectTotalShares() public {
        _generateInitData();
        initData.beneficiaries[0].shares -= 1;
        vm.expectRevert(abi.encodeWithSelector(InvalidTotalShares.selector));
        _initialize();
    }

    // TODO: Abstract this using the BeneficiaryData library tests
    function test_initialize_RevertInvalidProtocolOwnerShares() public {
        _generateInitData();
        initData.beneficiaries = new BeneficiaryData[](2);
        initData.beneficiaries[0] =
            BeneficiaryData({ beneficiary: address(1), shares: uint96(WAD - MIN_PROTOCOL_OWNER_SHARES + 1) });
        initData.beneficiaries[1] =
            BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: uint96(MIN_PROTOCOL_OWNER_SHARES - 1) });
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidProtocolOwnerShares.selector, MIN_PROTOCOL_OWNER_SHARES, MIN_PROTOCOL_OWNER_SHARES - 1
            )
        );
        _initialize();
    }

    // TODO: Abstract this using the BeneficiaryData library tests
    function test_initialize_RevertProtocolOwnerNotFound() public {
        _generateInitData();
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x123), shares: 0.4e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0x456), shares: 0.6e18 });
        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerBeneficiary.selector));
        _initialize();
    }

    function test_initialize_RevertDynamicFeeTooHigh() public {
        _generateInitData();
        initData.feeOrInitialDynamicFee = MAX_LP_FEE + 1;
        vm.expectRevert(abi.encodeWithSelector(LPFeeTooHigh.selector, MAX_LP_FEE, MAX_LP_FEE + 1));
        _initialize();
    }

    function test_initialize_RevertsWhenHookRequiresDynamicLPFee() public {
        _generateInitData();
        initData.feeOrInitialDynamicFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.expectRevert(HookRequiresDynamicLPFee.selector);
        _initialize();
    }

    /*
    function test_initialize_StoresSplitConfiguration() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        uint256 proceedsShare = 0.1e18;

        vm.prank(address(airlock));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(
                FEE,
                TICK_SPACING,
                LOCK_DURATION,
                beneficiaries,
                false,
                address(0),
                new bytes(0),
                new bytes(0),
                PROCEEDS_RECIPIENT,
                proceedsShare
            )
        );

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        (address storedRecipient, bool isToken0, uint256 storedShare) = migrator.splitConfigurationOf(token0, token1);
        assertEq(storedRecipient, PROCEEDS_RECIPIENT);
        assertEq(isToken0, asset < numeraire);
        assertEq(storedShare, proceedsShare);
    }

    function test_initialize_RevertsSplitShareTooHigh() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(SplitShareTooHigh.selector, 0.51e18, 0.5e18));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(
                FEE,
                TICK_SPACING,
                LOCK_DURATION,
                beneficiaries,
                false,
                address(0),
                new bytes(0),
                new bytes(0),
                PROCEEDS_RECIPIENT,
                uint256(0.51e18)
            )
        );
    }

    function test_initialize_FuzzDynamicFeeWithinCap(uint24 fee) public {
        vm.assume(fee <= 150_000);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            abi.encode(
                fee,
                TICK_SPACING,
                LOCK_DURATION,
                beneficiaries,
                address(0),
                new bytes(0),
                address(0),
                uint256(0)
            )
        );
    }

    /* ----------------------------------------------------------------------- */
    /*                                migrate()                                */
    /* ----------------------------------------------------------------------- */

    /*
        function test_migrate_RevertIfNotInitialized() public {
            vm.prank(address(airlock));
            vm.expectRevert(
                abi.encodeWithSelector(
                    WrongPoolStatus.selector, uint8(PoolStatus.Initialized), uint8(PoolStatus.Uninitialized)
                )
            );
            migrator.migrate(Constants.SQRT_PRICE_1_1, Currency.unwrap(currency0), Currency.unwrap(currency1), recipient);
        }

        function test_migrate_RevertIfHookDisabledAfterInitialize() public {
            BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
            beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
            beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

            address asset = Currency.unwrap(currency0);
            address numeraire = Currency.unwrap(currency1);
            address token0 = asset < numeraire ? asset : numeraire;
            address token1 = asset < numeraire ? numeraire : asset;
            address hookAddr = makeAddr("Hook");

            vm.prank(owner);
            migrator.setDopplerHookState(_singleAddr(hookAddr), _singleFlag(ON_AFTER_SWAP_FLAG));

            vm.prank(address(airlock));
            migrator.initialize(
                asset,
                numeraire,
                abi.encode(
                    FEE,
                    TICK_SPACING,
                    LOCK_DURATION,
                    beneficiaries,
                    false,
                    hookAddr,
                    new bytes(0),
                    new bytes(0),
                    address(0),
                    uint256(0)
                )
            );

            // Disable hook after initialize
            vm.prank(owner);
            migrator.setDopplerHookState(_singleAddr(hookAddr), _singleFlag(0));

            Currency.wrap(token0).transfer(address(migrator), 1e6);
            Currency.wrap(token1).transfer(address(migrator), 1e6);

            vm.prank(address(airlock));
            vm.expectRevert(abi.encodeWithSignature("DopplerHookNotEnabled()"));
            migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);
        }

        function test_migrate(bool isUsingETH, bool hasRecipient, uint64 balance0, uint64 balance1) public {
            vm.assume(balance0 > 1e6 && balance1 > 1e6);
            if (balance0 >= 1e12 || balance1 >= 1e12) return;
            vm.assume(balance0 < 1e12 && balance1 < 1e12);
            vm.assume(balance0 < 1e12 && balance1 < 1e12);

            bytes memory data = _prepareInitializeData();

            address asset = Currency.unwrap(currency0);
            address numeraire = Currency.unwrap(currency1);
            address token0 = asset < numeraire ? asset : numeraire;
            address token1 = asset < numeraire ? numeraire : asset;

            if (isUsingETH) {
                asset = numeraire;
                token1 = asset;
                token0 = address(0);
                numeraire = address(0);
            }

            vm.prank(address(airlock));
            migrator.initialize(asset, numeraire, data);

            if (isUsingETH) {
                deal(address(migrator), balance0);
            } else {
                Currency.wrap(token0).transfer(address(migrator), balance0);
            }
            Currency.wrap(token1).transfer(address(migrator), balance1);

            vm.prank(address(airlock));
            migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, hasRecipient ? recipient : address(0xdead));

            (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(token0, token1);
            (,, uint32 startDate,,) = locker.streams(poolKey.toId());
            assertGt(startDate, 0);

            if (isUsingETH) {
                assertEq(address(migrator).balance, 0);
            } else {
                assertEq(Currency.wrap(token0).balanceOf(address(migrator)), 0);
            }
            assertEq(Currency.wrap(token1).balanceOf(address(migrator)), 0);
        }

        function test_migrate_FuzzTickTwoSidedDoesNotRevert(int24 tick, uint32 balance0, uint32 balance1) public {
            vm.assume(balance0 > 1e6 && balance1 > 1e6);
            int24 minTick = TickMath.minUsableTick(TICK_SPACING);
            int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);
            vm.assume(tick >= minTick && tick <= maxTick);

            BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
            beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
            beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

            address asset = Currency.unwrap(currency0);
            address numeraire = Currency.unwrap(currency1);
            address token0 = asset < numeraire ? asset : numeraire;
            address token1 = asset < numeraire ? numeraire : asset;

            vm.prank(address(airlock));
            migrator.initialize(
                asset,
                numeraire,
                abi.encode(
                    FEE,
                    TICK_SPACING,
                    LOCK_DURATION,
                    beneficiaries,
                    false,
                    address(0),
                    new bytes(0),
                    new bytes(0),
                    address(0),
                    uint256(0)
                )
            );

            Currency.wrap(token0).transfer(address(migrator), balance0);
            Currency.wrap(token1).transfer(address(migrator), balance1);

            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(minTick), TickMath.getSqrtPriceAtTick(maxTick), balance0, balance1
            );
            vm.assume(liq > 0);
            vm.assume(liq <= uint128(type(int128).max));

            vm.prank(address(airlock));
            migrator.migrate(sqrtPriceX96, token0, token1, recipient);

            (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(token0, token1);
            (,, uint32 startDate,,) = locker.streams(poolKey.toId());
            assertGt(startDate, 0);
        }

        function test_migrate_DistributesSplitToRecipient() public {
            BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
            beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
            beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

            uint256 proceedsShare = 0.1e18; // 10%

            address asset = Currency.unwrap(currency0);
            address numeraire = Currency.unwrap(currency1);
            address token0 = asset < numeraire ? asset : numeraire;
            address token1 = asset < numeraire ? numeraire : asset;

            vm.prank(address(airlock));
            migrator.initialize(
                asset,
                numeraire,
                abi.encode(
                    FEE,
                    TICK_SPACING,
                    LOCK_DURATION,
                    beneficiaries,
                    false,
                    address(0),
                    new bytes(0),
                    new bytes(0),
                    PROCEEDS_RECIPIENT,
                    proceedsShare
                )
            );

            uint256 amount0 = 1e6;
            uint256 amount1 = 1e6;
            Currency.wrap(token0).transfer(address(migrator), amount0);
            Currency.wrap(token1).transfer(address(migrator), amount1);

            vm.prank(address(airlock));
            migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

            // Asset is token0, so numeraire is token1. Split comes from numeraire (token1).
            // Expected split = amount1 * 10% = 1e5
            bool isToken0 = asset == token0;
            if (isToken0) {
                uint256 expectedSplit = amount1 * proceedsShare / 1e18;
                assertEq(Currency.wrap(token1).balanceOf(PROCEEDS_RECIPIENT), expectedSplit);
            } else {
                uint256 expectedSplit = amount0 * proceedsShare / 1e18;
                assertEq(Currency.wrap(token0).balanceOf(PROCEEDS_RECIPIENT), expectedSplit);
            }

            // Migrator should have no tokens left
            assertEq(Currency.wrap(token0).balanceOf(address(migrator)), 0);
            assertEq(Currency.wrap(token1).balanceOf(address(migrator)), 0);
        }

        function test_migrate_NoSplitDistribution() public {
            BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
            beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
            beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

            address asset = Currency.unwrap(currency0);
            address numeraire = Currency.unwrap(currency1);
            address token0 = asset < numeraire ? asset : numeraire;
            address token1 = asset < numeraire ? numeraire : asset;

            vm.prank(address(airlock));
            migrator.initialize(
                asset,
                numeraire,
                abi.encode(
                    FEE,
                    TICK_SPACING,
                    LOCK_DURATION,
                    beneficiaries,
                    false,
                    address(0),
                    new bytes(0),
                    new bytes(0),
                    PROCEEDS_RECIPIENT,
                    uint256(0)
                )
            );

            uint256 amount0 = 1e6;
            uint256 amount1 = 1e6;
            Currency.wrap(token0).transfer(address(migrator), amount0);
            Currency.wrap(token1).transfer(address(migrator), amount1);

            vm.prank(address(airlock));
            migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

            // No split, proceeds recipient should have nothing
            assertEq(Currency.wrap(token0).balanceOf(PROCEEDS_RECIPIENT), 0);
            assertEq(Currency.wrap(token1).balanceOf(PROCEEDS_RECIPIENT), 0);

            // Migrator should have no tokens left
            assertEq(Currency.wrap(token0).balanceOf(address(migrator)), 0);
            assertEq(Currency.wrap(token1).balanceOf(address(migrator)), 0);
        }

        function test_migrate_DistributesSplitWithETH() public {
            BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
            beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
            beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

            uint256 proceedsShare = 0.1e18; // 10%

            // ETH as numeraire: token0 = address(0), token1 = asset
            address asset = Currency.unwrap(currency1);
            address numeraire = address(0);
            address token0 = address(0);
            address token1 = asset;

            vm.prank(address(airlock));
            migrator.initialize(
                asset,
                numeraire,
                abi.encode(
                    FEE,
                    TICK_SPACING,
                    LOCK_DURATION,
                    beneficiaries,
                    false,
                    address(0),
                    new bytes(0),
                    new bytes(0),
                    PROCEEDS_RECIPIENT,
                    proceedsShare
                )
            );

            uint256 ethAmount = 1e6;
            uint256 tokenAmount = 1e6;
            deal(address(migrator), ethAmount);
            Currency.wrap(token1).transfer(address(migrator), tokenAmount);

            uint256 recipientBalanceBefore = PROCEEDS_RECIPIENT.balance;

            vm.prank(address(airlock));
            migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

            // Asset is token1, numeraire is ETH (token0). Split comes from numeraire (ETH).
            uint256 expectedSplit = ethAmount * proceedsShare / 1e18;
            assertEq(PROCEEDS_RECIPIENT.balance - recipientBalanceBefore, expectedSplit);

            // Migrator should have no ETH or tokens left
            assertEq(address(migrator).balance, 0);
            assertEq(Currency.wrap(token1).balanceOf(address(migrator)), 0);
        }

        function test_migrate_SetsInitialDynamicFee() public {
            BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
            beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
            beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

            address asset = Currency.unwrap(currency0);
            address numeraire = Currency.unwrap(currency1);
            address token0 = asset < numeraire ? asset : numeraire;
            address token1 = asset < numeraire ? numeraire : asset;

            vm.prank(address(airlock));
            migrator.initialize(
                asset,
                numeraire,
                abi.encode(
                    10_000,
                    TICK_SPACING,
                    LOCK_DURATION,
                    beneficiaries,
                    true,
                    address(0),
                    new bytes(0),
                    new bytes(0),
                    address(0),
                    uint256(0)
                )
            );

            Currency.wrap(token0).transfer(address(migrator), 1e6);
            Currency.wrap(token1).transfer(address(migrator), 1e6);

            vm.prank(address(airlock));
            migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

            (, PoolKey memory poolKey,,,,,,) = migrator.getAssetData(token0, token1);
            (,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolKey.toId());
            assertEq(protocolFee, 0);
            assertEq(lpFee, 10_000);
        }
        */

    /* ----------------------------------------------------------------------------------- */
    /*                                setDopplerHookState()                                */
    /* ----------------------------------------------------------------------------------- */

    /*
    function test_setDopplerHookState_StoresFlags(address[] calldata dopplerHooks, uint256[] calldata flags) public {
        vm.assume(dopplerHooks.length == flags.length);
        vm.prank(owner);
        migrator.setDopplerHookState(dopplerHooks, flags);
        for (uint256 i; i < dopplerHooks.length; i++) {
            assertEq(migrator.isDopplerHookEnabled(dopplerHooks[i]), flags[i]);
        }
    }

    function test_setDopplerHookState_RevertLengthMismatch(
        address[] calldata dopplerHooks,
        uint256[] calldata flags
    ) public {
        vm.assume(dopplerHooks.length != flags.length);
        vm.prank(owner);
        vm.expectRevert(ArrayLengthsMismatch.selector);
        migrator.setDopplerHookState(dopplerHooks, flags);
    }

    function test_setDopplerHookState_RevertIfNotOwner(
        address sender,
        address[] calldata dopplerHooks,
        uint256[] calldata flags
    ) public {
        vm.assume(sender != airlock.owner());
        vm.assume(dopplerHooks.length == flags.length);
        vm.expectRevert(SenderNotAirlockOwner.selector);
        migrator.setDopplerHookState(dopplerHooks, flags);
    }
    */

    /* ------------------------------------------------------------------------------ */
    /*                                setDopplerHook()                                */
    /* ------------------------------------------------------------------------------ */

    /*
    function test_setDopplerHook_RevertUnauthorized() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(
                FEE, false, TICK_SPACING, LOCK_DURATION, beneficiaries, address(0), new bytes(0), address(0), uint256(0)
            )
        );

        Currency.wrap(asset < numeraire ? asset : numeraire).transfer(address(migrator), 1e6);
        Currency.wrap(asset < numeraire ? numeraire : asset).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(
            Constants.SQRT_PRICE_1_1,
            asset < numeraire ? asset : numeraire,
            asset < numeraire ? numeraire : asset,
            recipient
        );

        airlock.setTimelock(asset, owner);
        vm.expectRevert(abi.encodeWithSignature("SenderNotAuthorized()"));
        migrator.setDopplerHook(asset, makeAddr("Hook"), new bytes(0));
    }

    function test_setDopplerHook_RevertNotEnabled() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(
                FEE, false, TICK_SPACING, LOCK_DURATION, beneficiaries, address(0), new bytes(0), address(0), uint256(0)
            )
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        airlock.setTimelock(asset, owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("DopplerHookNotEnabled()"));
        migrator.setDopplerHook(asset, makeAddr("Hook"), new bytes(0));
    }

    function test_setDopplerHook_RevertRequiresDynamicFee() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        address hookAddr = makeAddr("Hook");
        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(hookAddr), _singleFlag(REQUIRES_DYNAMIC_LP_FEE_FLAG));

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(
                FEE, false, TICK_SPACING, LOCK_DURATION, beneficiaries, address(0), new bytes(0), address(0), uint256(0)
            )
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        airlock.setTimelock(asset, owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("HookRequiresDynamicLPFee()"));
        migrator.setDopplerHook(asset, hookAddr, new bytes(0));
    }

    function test_setDopplerHook_CallsOnInitialization() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        address mockDopplerHookMigrator = makeAddr("MockDopplerHookMigrator");
        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(mockDopplerHookMigrator), _singleFlag(ON_INITIALIZATION_FLAG));

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(
                FEE, false, TICK_SPACING, LOCK_DURATION, beneficiaries, address(0), new bytes(0), address(0), uint256(0)
            )
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        vm.expectCall(
            mockDopplerHookMigrator,
            abi.encodeWithSelector(IDopplerHookMigrator.onInitialization.selector, asset, key, new bytes(0))
        );

        vm.prank(owner);
        migrator.setDopplerHook(asset, address(mockDopplerHookMigrator), new bytes(0));
    }
    */

    /* ---------------------------------------------------------------------------------- */
    /*                                updateDynamicLPFee()                                */
    /* ---------------------------------------------------------------------------------- */

    /*
    function test_updateDynamicLPFee_RevertUnauthorized() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);
        address token0 = asset < numeraire ? asset : numeraire;
        address token1 = asset < numeraire ? numeraire : asset;

        MockDopplerHook mockHook = new MockDopplerHook(address(migrator));
        assertTrue(address(mockHook) != address(this));

        vm.prank(owner);
        migrator.setDopplerHookState(_singleAddr(address(mockHook)), _singleFlag(ON_AFTER_SWAP_FLAG));

        vm.prank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(
                10_000,
                true,
                TICK_SPACING,
                LOCK_DURATION,
                beneficiaries,
                address(mockHook),
                new bytes(0),
                address(0),
                uint256(0)
            )
        );

        Currency.wrap(token0).transfer(address(migrator), 1e6);
        Currency.wrap(token1).transfer(address(migrator), 1e6);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

        (, PoolKey memory key,,, bool useDynamicFee, address storedHook,,) = migrator.getAssetData(token0, token1);
        assertEq(storedHook, address(mockHook));
        assertEq(address(key.hooks), address(migrator));
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertTrue(useDynamicFee);
        vm.expectRevert(abi.encodeWithSignature("SenderNotAuthorized()"));
        migrator.updateDynamicLPFee(asset, 1000);
    }
    */

    /*

     function test_updateDynamicLPFee_SucceedsForHook() public {
         BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
         beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
         beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

         address asset = Currency.unwrap(currency0);
         address numeraire = Currency.unwrap(currency1);
         address token0 = asset < numeraire ? asset : numeraire;
         address token1 = asset < numeraire ? numeraire : asset;

         MockDopplerHook mockHook = new MockDopplerHook(address(migrator));

         vm.prank(owner);
         migrator.setDopplerHookState(_singleAddr(address(mockHook)), _singleFlag(ON_AFTER_SWAP_FLAG));

         vm.prank(address(airlock));
         migrator.initialize(
             asset,
             numeraire,
             abi.encode(
                 10_000,
                 TICK_SPACING,
                 LOCK_DURATION,
                 beneficiaries,
                 true,
                 address(mockHook),
                 new bytes(0),
                 new bytes(0),
                 address(0),
                 uint256(0)
             )
         );

         Currency.wrap(token0).transfer(address(migrator), 1e6);
         Currency.wrap(token1).transfer(address(migrator), 1e6);

         vm.prank(address(airlock));
         migrator.migrate(Constants.SQRT_PRICE_1_1, token0, token1, recipient);

         (, PoolKey memory key,,, bool useDynamicFee, address storedHook,,) = migrator.getAssetData(token0, token1);
         assertEq(storedHook, address(mockHook));
         assertEq(address(key.hooks), address(migrator));
         assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
         assertTrue(useDynamicFee);
         vm.prank(address(mockHook));
         migrator.updateDynamicLPFee(asset, 1000);
     }
     */

    /* ------------------------------------------------------------------------------ */
    /*                                     Utils                                      */
    /* ------------------------------------------------------------------------------ */

    function _singleAddr(address value) private pure returns (address[] memory addrs) {
        addrs = new address[](1);
        addrs[0] = value;
    }

    function _singleFlag(uint256 value) private pure returns (uint256[] memory flags) {
        flags = new uint256[](1);
        flags[0] = value;
    }

    function _initialize() internal {
        vm.prank(address(airlock));
        migrator.initialize(asset, numeraire, _encodeInitData());
    }

    function _encodeInitData() internal view returns (bytes memory) {
        return abi.encode(
            initData.feeOrInitialDynamicFee,
            initData.useDynamicFee,
            initData.tickSpacing,
            initData.lockDuration,
            initData.beneficiaries,
            initData.dopplerHookMigrator,
            initData.onInitializationCalldata,
            initData.proceedsRecipient,
            initData.proceedsShare
        );
    }

    function _generateInitData() internal {
        isToken0 = vm.randomBool();
        isUsingETH = vm.randomBool();

        if (isUsingETH) {
            currency0 = Currency.wrap(address(0));
            asset = Currency.unwrap(currency1);
            numeraire = address(0);
        } else {
            asset = isToken0 ? Currency.unwrap(currency0) : Currency.unwrap(currency1);
            numeraire = isToken0 ? Currency.unwrap(currency1) : Currency.unwrap(currency0);
        }

        initData = InitData({
            feeOrInitialDynamicFee: uint24(vm.randomUint(0, uint256(MAX_LP_FEE))),
            useDynamicFee: false,
            tickSpacing: int24(
                uint24(
                    vm.randomUint(
                        uint256(uint24(TickMath.MIN_TICK_SPACING)), uint256(uint24(TickMath.MAX_TICK_SPACING))
                    )
                )
            ),
            lockDuration: uint32(vm.randomUint(0, type(uint32).max)),
            beneficiaries: generateBeneficiaries(PROTOCOL_OWNER, vm.randomUint()),
            dopplerHookMigrator: address(0),
            onInitializationCalldata: new bytes(0),
            proceedsRecipient: address(0),
            proceedsShare: 0
        });
    }
}
