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
import { MAX_SPLIT_SHARE } from "src/base/ProceedsSplitter.sol";
import { IDopplerHookMigrator } from "src/interfaces/IDopplerHookMigrator.sol";
import {
    ArrayLengthsMismatch,
    AssetData,
    DelegateAuthority,
    DopplerHookMigrator,
    DopplerHookNotEnabled,
    HookRequiresDynamicLPFee,
    LPFeeTooHigh,
    MAX_LP_FEE,
    OnlySelf,
    PoolNotDynamicFee,
    PoolStatus,
    SenderNotAirlockOwner,
    SenderNotAuthorized,
    SetDopplerHook,
    WrongPoolStatus,
    ZeroLiquidity
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
import { WAD } from "src/types/Wad.sol";
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
    address PROTOCOL_OWNER = address(0xb055);
    address PROCEEDS_RECIPIENT = makeAddr("PROCEEDS_RECIPIENT");
    address RECIPIENT = makeAddr("RECIPIENT");
    address TIMELOCK = makeAddr("TIMELOCK");

    uint256 constant BALANCE = 1e6;

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

    /* --------------------------------------------------------------------------- */
    /*                                initialize()                                 */
    /* --------------------------------------------------------------------------- */

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
        initData.beneficiaries = new BeneficiaryData[](2);
        initData.beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x123), shares: 0.4e18 });
        initData.beneficiaries[1] = BeneficiaryData({ beneficiary: address(0x456), shares: 0.6e18 });
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
        initData.useDynamicFee = true;
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(_singleAddr(initData.dopplerHookMigrator), _singleFlag(ON_AFTER_SWAP_FLAG));
        vm.expectRevert(HookRequiresDynamicLPFee.selector);
        _initialize();
    }

    // TODO: Abstract this using the ProceedsSplitter base contract tests
    function test_initialize_StoresSplitConfiguration() public {
        _generateInitData();
        initData.proceedsRecipient = PROCEEDS_RECIPIENT;
        initData.proceedsShare = 0.1e18;
        _initialize();

        (address storedRecipient, bool isToken0_, uint256 storedShare) =
            migrator.splitConfigurationOf(Currency.unwrap(currency0), Currency.unwrap(currency1));
        assertEq(storedRecipient, PROCEEDS_RECIPIENT, "Stored recipient is wrong");
        assertEq(isToken0, isToken0_, "Stored isToken0 is wrong");
        assertEq(storedShare, initData.proceedsShare, "Stored share is wrong");
    }

    // TODO: Abstract this using the ProceedsSplitter base contract tests
    function test_initialize_RevertsSplitShareTooHigh() public {
        _generateInitData();
        initData.proceedsRecipient = PROCEEDS_RECIPIENT;
        initData.proceedsShare = MAX_SPLIT_SHARE + 1;
        vm.expectRevert(abi.encodeWithSelector(SplitShareTooHigh.selector, initData.proceedsShare, 0.5e18));
        _initialize();
    }

    function test_initialize_RevertsWhenTickSpacingTooLarge() public {
        _generateInitData();
        initData.tickSpacing = TickMath.MAX_TICK_SPACING + 1;
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooLarge.selector, initData.tickSpacing));
        _initialize();
    }

    function test_initialize_RevertsWhenTickSpacingTooSmall() public {
        _generateInitData();
        initData.tickSpacing = 0;
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.TickSpacingTooSmall.selector, int24(0)));
        _initialize();
    }

    function test_initialize_RevertsWhenAlreadyInitialized() public {
        _generateInitData();
        _initialize();
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongPoolStatus.selector, uint8(PoolStatus.Uninitialized), uint8(PoolStatus.Initialized)
            )
        );
        _initialize();
    }

    function test_initialize_RevertsWhenHookNotEnabled() public {
        _generateInitData();
        initData.dopplerHookMigrator = vm.randomAddress();
        // Don't enable the hook → flags == 0
        vm.expectRevert(DopplerHookNotEnabled.selector);
        _initialize();
    }

    function test_initialize_WithHookAndDynamicFee() public {
        _generateInitData();
        initData.useDynamicFee = true;
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(
            _singleAddr(initData.dopplerHookMigrator),
            _singleFlag(ON_AFTER_SWAP_FLAG | REQUIRES_DYNAMIC_LP_FEE_FLAG)
        );
        _initialize();

        (,,, uint24 feeOrInitialDynamicFee, bool useDynamicFee, address dopplerHook,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        assertTrue(useDynamicFee);
        assertEq(dopplerHook, initData.dopplerHookMigrator);
        assertEq(feeOrInitialDynamicFee, initData.feeOrInitialDynamicFee);
    }

    /* ----------------------------------------------------------------------- */
    /*                                migrate()                                */
    /* ----------------------------------------------------------------------- */

    function test_migrate_RevertIfNotInitialized() public {
        vm.prank(address(airlock));
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongPoolStatus.selector, uint8(PoolStatus.Initialized), uint8(PoolStatus.Uninitialized)
            )
        );
        migrator.migrate(Constants.SQRT_PRICE_1_1, Currency.unwrap(currency0), Currency.unwrap(currency1), address(0));
    }

    function test_migrate_RevertIfHookDisabledAfterInitialize() public {
        _generateInitData();
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(_singleAddr(initData.dopplerHookMigrator), _singleFlag(ON_AFTER_SWAP_FLAG));
        _initialize();

        // Disable hook after initialize
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(_singleAddr(initData.dopplerHookMigrator), _singleFlag(0));

        _fundMigrator(BALANCE, BALANCE);
        vm.prank(address(airlock));
        vm.expectRevert(DopplerHookNotEnabled.selector);
        migrator.migrate(Constants.SQRT_PRICE_1_1, Currency.unwrap(currency0), Currency.unwrap(currency1), RECIPIENT);
    }

    function test_migrate(uint64 balance0, uint64 balance1) public {
        vm.assume(balance0 > 1e6 && balance1 > 1e6);
        vm.assume(balance0 < 1e12 && balance1 < 1e12);

        _generateInitData();
        _initialize();
        _fundMigrator(balance0, balance1);
        _migrate();

        (, PoolKey memory poolKey,,,,,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        (,, uint32 startDate,,) = locker.streams(poolKey.toId());
        assertGt(startDate, 0);

        assertEq(currency0.balanceOf(address(migrator)), 0);
        assertEq(currency1.balanceOf(address(migrator)), 0);
    }

    function test_migrate_FuzzTickTwoSidedDoesNotRevert(int24 tick, uint32 balance0, uint32 balance1) public {
        vm.assume(balance0 > 1e6 && balance1 > 1e6);

        _generateInitData();

        int24 tickSpacing = initData.tickSpacing;
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        vm.assume(tick >= minTick && tick <= maxTick);

        _initialize();
        _fundMigrator(balance0, balance1);

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(minTick), TickMath.getSqrtPriceAtTick(maxTick), balance0, balance1
        );
        vm.assume(liq > 0);
        vm.assume(liq <= uint128(type(int128).max));

        _migrate(sqrtPriceX96);

        (, PoolKey memory poolKey,,,,,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        (,, uint32 startDate,,) = locker.streams(poolKey.toId());
        assertGt(startDate, 0);
    }

    function test_migrate_DistributesSplitToRecipient() public {
        _generateInitData();
        initData.proceedsRecipient = PROCEEDS_RECIPIENT;
        initData.proceedsShare = 0.1e18;
        _initialize();
        _fundMigrator(BALANCE, BALANCE);
        _migrate();

        uint256 expectedSplit = BALANCE * initData.proceedsShare / 1e18;
        if (isToken0) {
            // asset=token0, numeraire=token1
            assertEq(currency1.balanceOf(PROCEEDS_RECIPIENT), expectedSplit);
        } else {
            // asset=token1, numeraire=token0
            assertEq(currency0.balanceOf(PROCEEDS_RECIPIENT), expectedSplit);
        }

        assertEq(currency0.balanceOf(address(migrator)), 0);
        assertEq(currency1.balanceOf(address(migrator)), 0);
    }

    function test_migrate_NoSplitDistribution() public {
        _generateInitData();
        // Default: proceedsRecipient=address(0), proceedsShare=0 — no split configured
        _initialize();
        _fundMigrator(BALANCE, BALANCE);
        _migrate();

        assertEq(currency0.balanceOf(PROCEEDS_RECIPIENT), 0);
        assertEq(currency1.balanceOf(PROCEEDS_RECIPIENT), 0);

        assertEq(currency0.balanceOf(address(migrator)), 0);
        assertEq(currency1.balanceOf(address(migrator)), 0);
    }

    function test_migrate_DistributesSplitWithETH() public {
        // Force ETH as numeraire
        currency0 = Currency.wrap(address(0));
        asset = Currency.unwrap(currency1);
        numeraire = address(0);
        isToken0 = false;
        isUsingETH = true;

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
            proceedsRecipient: PROCEEDS_RECIPIENT,
            proceedsShare: 0.1e18
        });

        _initialize();
        _fundMigrator(BALANCE, BALANCE);

        uint256 recipientBalanceBefore = PROCEEDS_RECIPIENT.balance;
        _migrate();

        // Asset is token1, numeraire is ETH (token0). Split comes from numeraire (ETH).
        uint256 expectedSplit = BALANCE * initData.proceedsShare / 1e18;
        assertEq(PROCEEDS_RECIPIENT.balance - recipientBalanceBefore, expectedSplit);

        assertEq(address(migrator).balance, 0);
        assertEq(currency1.balanceOf(address(migrator)), 0);
    }

    function test_migrate_SetsInitialDynamicFee() public {
        _generateInitData();
        initData.useDynamicFee = true;
        initData.feeOrInitialDynamicFee = 10_000;
        _initialize();
        _fundMigrator(BALANCE, BALANCE);
        _migrate();

        (, PoolKey memory poolKey,,,,,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        (,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolKey.toId());
        assertEq(protocolFee, 0);
        assertEq(lpFee, 10_000);
    }

    function test_migrate_RevertsWhenAlreadyMigrated() public {
        _generateInitData();
        _initializeAndMigrate();

        _fundMigrator(BALANCE, BALANCE);
        vm.prank(address(airlock));
        vm.expectRevert(
            abi.encodeWithSelector(WrongPoolStatus.selector, uint8(PoolStatus.Initialized), uint8(PoolStatus.Locked))
        );
        migrator.migrate(Constants.SQRT_PRICE_1_1, Currency.unwrap(currency0), Currency.unwrap(currency1), RECIPIENT);
    }

    function test_migrate_RevertsWhenZeroLiquidity() public {
        _generateInitData();
        _initialize();
        // Don't fund the migrator → zero balances → zero liquidity
        vm.prank(address(airlock));
        vm.expectRevert(ZeroLiquidity.selector);
        migrator.migrate(Constants.SQRT_PRICE_1_1, Currency.unwrap(currency0), Currency.unwrap(currency1), RECIPIENT);
    }

    function test_migrate_CallsHookOnInitialization() public {
        _generateInitData();
        address mockHook = makeAddr("MockHook");
        initData.dopplerHookMigrator = mockHook;
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(
            _singleAddr(mockHook), _singleFlag(ON_INITIALIZATION_FLAG | ON_AFTER_SWAP_FLAG)
        );
        _initialize();
        _fundMigrator(BALANCE, BALANCE);

        (, PoolKey memory poolKey,,,,,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));

        vm.mockCall(mockHook, abi.encodeWithSelector(IDopplerHookMigrator.onInitialization.selector), abi.encode());
        vm.expectCall(
            mockHook,
            abi.encodeWithSelector(
                IDopplerHookMigrator.onInitialization.selector, asset, poolKey, initData.onInitializationCalldata
            )
        );
        _migrate();
    }

    function test_migrate_RevertsWhenDynamicFeeFlagRemovedAfterInit() public {
        _generateInitData();
        initData.useDynamicFee = true;
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(
            _singleAddr(initData.dopplerHookMigrator),
            _singleFlag(ON_AFTER_SWAP_FLAG | REQUIRES_DYNAMIC_LP_FEE_FLAG)
        );
        _initialize();

        // Remove REQUIRES_DYNAMIC_LP_FEE_FLAG after init
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(
            _singleAddr(initData.dopplerHookMigrator), _singleFlag(ON_AFTER_SWAP_FLAG)
        );

        _fundMigrator(BALANCE, BALANCE);
        vm.prank(address(airlock));
        vm.expectRevert(HookRequiresDynamicLPFee.selector);
        migrator.migrate(Constants.SQRT_PRICE_1_1, Currency.unwrap(currency0), Currency.unwrap(currency1), RECIPIENT);
    }

    /* ----------------------------------------------------------------------------------- */
    /*                                setDopplerHookState()                                */
    /* ----------------------------------------------------------------------------------- */

    function test_setDopplerHookState_StoresFlags(address[] calldata dopplerHooks, uint256[] calldata flags) public {
        vm.assume(dopplerHooks.length == flags.length);
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(dopplerHooks, flags);
        for (uint256 i; i < dopplerHooks.length; i++) {
            // Only check the last occurrence of each address (duplicates overwrite in the mapping)
            bool isLastOccurrence = true;
            for (uint256 j = i + 1; j < dopplerHooks.length; j++) {
                if (dopplerHooks[j] == dopplerHooks[i]) {
                    isLastOccurrence = false;
                    break;
                }
            }
            if (isLastOccurrence) {
                assertEq(migrator.isDopplerHookEnabled(dopplerHooks[i]), flags[i]);
            }
        }
    }

    function test_setDopplerHookState_RevertLengthMismatch(
        address[] calldata dopplerHooks,
        uint256[] calldata flags
    ) public {
        vm.assume(dopplerHooks.length != flags.length);
        vm.prank(PROTOCOL_OWNER);
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
        vm.prank(sender);
        vm.expectRevert(SenderNotAirlockOwner.selector);
        migrator.setDopplerHookState(dopplerHooks, flags);
    }

    /* ------------------------------------------------------------------------------ */
    /*                              delegateAuthority()                              */
    /* ------------------------------------------------------------------------------ */

    function test_delegateAuthority_StoresAuthority() public {
        address user = makeAddr("User");
        address authority = makeAddr("Authority");
        vm.prank(user);
        migrator.delegateAuthority(authority);
        assertEq(migrator.getAuthority(user), authority);
    }

    function test_delegateAuthority_EmitsEvent() public {
        address user = makeAddr("User");
        address authority = makeAddr("Authority");
        vm.prank(user);
        vm.expectEmit(true, true, false, false);
        emit DelegateAuthority(user, authority);
        migrator.delegateAuthority(authority);
    }

    /* ------------------------------------------------------------------------------ */
    /*                                setDopplerHook()                                */
    /* ------------------------------------------------------------------------------ */

    function test_setDopplerHook_RevertUnauthorized() public {
        _generateInitData();
        _initializeAndMigrate();

        _mockAirlockTimelock();
        // Call without pranking as TIMELOCK → SenderNotAuthorized
        vm.expectRevert(SenderNotAuthorized.selector);
        migrator.setDopplerHook(asset, makeAddr("Hook"), new bytes(0));
    }

    function test_setDopplerHook_RevertNotEnabled() public {
        _generateInitData();
        _initializeAndMigrate();

        _mockAirlockTimelock();
        vm.prank(TIMELOCK);
        vm.expectRevert(DopplerHookNotEnabled.selector);
        migrator.setDopplerHook(asset, makeAddr("Hook"), new bytes(0));
    }

    function test_setDopplerHook_RevertRequiresDynamicFee() public {
        _generateInitData();
        initData.useDynamicFee = true;
        // dopplerHook=address(0) during init skips the hook check
        _initializeAndMigrate();

        // Enable a hook WITHOUT REQUIRES_DYNAMIC_LP_FEE_FLAG
        address hookAddr = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(_singleAddr(hookAddr), _singleFlag(ON_AFTER_SWAP_FLAG));

        _mockAirlockTimelock();
        vm.prank(TIMELOCK);
        vm.expectRevert(HookRequiresDynamicLPFee.selector);
        migrator.setDopplerHook(asset, hookAddr, new bytes(0));
    }

    function test_setDopplerHook_CallsOnInitialization() public {
        _generateInitData();
        _initializeAndMigrate();

        address mockHook = makeAddr("MockHook");
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(_singleAddr(mockHook), _singleFlag(ON_INITIALIZATION_FLAG));

        _mockAirlockTimelock();

        (, PoolKey memory poolKey,,,,,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));

        vm.mockCall(mockHook, abi.encodeWithSelector(IDopplerHookMigrator.onInitialization.selector), abi.encode());
        vm.expectCall(
            mockHook,
            abi.encodeWithSelector(IDopplerHookMigrator.onInitialization.selector, asset, poolKey, new bytes(0))
        );

        vm.prank(TIMELOCK);
        migrator.setDopplerHook(asset, mockHook, new bytes(0));
    }

    function test_setDopplerHook_StoresHook() public {
        _generateInitData();
        _initializeAndMigrate();

        address mockHook = makeAddr("MockHook");
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(_singleAddr(mockHook), _singleFlag(ON_AFTER_SWAP_FLAG));

        _mockAirlockTimelock();

        vm.prank(TIMELOCK);
        vm.expectEmit(true, true, false, false);
        emit SetDopplerHook(asset, mockHook);
        migrator.setDopplerHook(asset, mockHook, new bytes(0));

        (,,,,, address storedHook,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        assertEq(storedHook, mockHook);
    }

    function test_setDopplerHook_UnsetsHook() public {
        _generateInitData();
        _initializeAndMigrate();

        address mockHook = makeAddr("MockHook");
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(_singleAddr(mockHook), _singleFlag(ON_AFTER_SWAP_FLAG));

        _mockAirlockTimelock();

        // Set the hook
        vm.prank(TIMELOCK);
        migrator.setDopplerHook(asset, mockHook, new bytes(0));

        // Unset the hook
        vm.prank(TIMELOCK);
        migrator.setDopplerHook(asset, address(0), new bytes(0));

        (,,,,, address storedHook,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        assertEq(storedHook, address(0));
    }

    function test_setDopplerHook_ViaDelegatedAuthority() public {
        _generateInitData();
        _initializeAndMigrate();

        address mockHook = makeAddr("MockHook");
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(_singleAddr(mockHook), _singleFlag(ON_AFTER_SWAP_FLAG));

        _mockAirlockTimelock();

        address delegatedAddr = makeAddr("Delegated");
        vm.prank(TIMELOCK);
        migrator.delegateAuthority(delegatedAddr);

        vm.prank(delegatedAddr);
        migrator.setDopplerHook(asset, mockHook, new bytes(0));

        (,,,,, address storedHook,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        assertEq(storedHook, mockHook);
    }

    function test_setDopplerHook_RevertWrongPoolStatus() public {
        _generateInitData();
        _initialize();
        // Pool is Initialized (not Locked). getPair[asset] is unset → returns zeros → status is Uninitialized.
        vm.expectRevert(
            abi.encodeWithSelector(WrongPoolStatus.selector, uint8(PoolStatus.Locked), uint8(PoolStatus.Uninitialized))
        );
        migrator.setDopplerHook(asset, address(0), new bytes(0));
    }

    /* ---------------------------------------------------------------------------------- */
    /*                                updateDynamicLPFee()                                */
    /* ---------------------------------------------------------------------------------- */

    function test_updateDynamicLPFee_RevertUnauthorized() public {
        _generateInitData();
        initData.useDynamicFee = true;
        initData.feeOrInitialDynamicFee = 10_000;
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(
            _singleAddr(initData.dopplerHookMigrator), _singleFlag(REQUIRES_DYNAMIC_LP_FEE_FLAG)
        );
        _initializeAndMigrate();

        (, PoolKey memory key,,, bool useDynamicFee, address storedHook,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        assertEq(storedHook, initData.dopplerHookMigrator);
        assertEq(address(key.hooks), address(migrator));
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertTrue(useDynamicFee);

        // Caller is not the stored hook → SenderNotAuthorized
        vm.expectRevert(SenderNotAuthorized.selector);
        migrator.updateDynamicLPFee(asset, 1000);
    }

    function test_updateDynamicLPFee_SucceedsForHook() public {
        _generateInitData();
        initData.useDynamicFee = true;
        initData.feeOrInitialDynamicFee = 10_000;
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(
            _singleAddr(initData.dopplerHookMigrator), _singleFlag(REQUIRES_DYNAMIC_LP_FEE_FLAG)
        );
        _initializeAndMigrate();

        (, PoolKey memory key,,, bool useDynamicFee, address storedHook,,) =
            migrator.getAssetData(Currency.unwrap(currency0), Currency.unwrap(currency1));
        assertEq(storedHook, initData.dopplerHookMigrator);
        assertEq(address(key.hooks), address(migrator));
        assertEq(key.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertTrue(useDynamicFee);

        vm.prank(initData.dopplerHookMigrator);
        migrator.updateDynamicLPFee(asset, 1000);

        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 1000);
    }

    function test_updateDynamicLPFee_RevertsWhenPoolNotDynamic() public {
        _generateInitData();
        initData.useDynamicFee = false;
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(
            _singleAddr(initData.dopplerHookMigrator), _singleFlag(ON_AFTER_SWAP_FLAG)
        );
        _initializeAndMigrate();

        vm.prank(initData.dopplerHookMigrator);
        vm.expectRevert(PoolNotDynamicFee.selector);
        migrator.updateDynamicLPFee(asset, 1000);
    }

    function test_updateDynamicLPFee_RevertsWhenFeeTooHigh() public {
        _generateInitData();
        initData.useDynamicFee = true;
        initData.feeOrInitialDynamicFee = 10_000;
        initData.dopplerHookMigrator = vm.randomAddress();
        vm.prank(PROTOCOL_OWNER);
        migrator.setDopplerHookState(
            _singleAddr(initData.dopplerHookMigrator), _singleFlag(REQUIRES_DYNAMIC_LP_FEE_FLAG)
        );
        _initializeAndMigrate();

        vm.prank(initData.dopplerHookMigrator);
        vm.expectRevert(abi.encodeWithSelector(LPFeeTooHigh.selector, MAX_LP_FEE, uint256(MAX_LP_FEE) + 1));
        migrator.updateDynamicLPFee(asset, MAX_LP_FEE + 1);
    }

    function test_updateDynamicLPFee_RevertsWhenWrongPoolStatus() public {
        address fakeAsset = makeAddr("FakeAsset");
        vm.expectRevert(
            abi.encodeWithSelector(WrongPoolStatus.selector, uint8(PoolStatus.Locked), uint8(PoolStatus.Uninitialized))
        );
        migrator.updateDynamicLPFee(fakeAsset, 1000);
    }

    /* ------------------------------------------------------------------------------ */
    /*                              Hook callbacks                                    */
    /* ------------------------------------------------------------------------------ */

    function test_beforeInitialize_RevertsWhenNotSelf() public {
        PoolKey memory key;
        vm.prank(address(manager));
        vm.expectRevert(OnlySelf.selector);
        migrator.beforeInitialize(address(this), key, Constants.SQRT_PRICE_1_1);
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory perms = migrator.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertTrue(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

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

    function _fundMigrator(uint256 amount0, uint256 amount1) internal {
        if (isUsingETH) {
            deal(address(migrator), amount0);
        } else {
            currency0.transfer(address(migrator), amount0);
        }
        currency1.transfer(address(migrator), amount1);
    }

    function _migrate() internal {
        _migrate(Constants.SQRT_PRICE_1_1);
    }

    function _migrate(uint160 sqrtPriceX96) internal {
        vm.prank(address(airlock));
        migrator.migrate(sqrtPriceX96, Currency.unwrap(currency0), Currency.unwrap(currency1), RECIPIENT);
    }

    function _initializeAndMigrate() internal {
        _initialize();
        _fundMigrator(BALANCE, BALANCE);
        _migrate();
    }

    function _mockAirlockTimelock() internal {
        vm.mockCall(
            address(airlock),
            abi.encodeWithSignature("getAssetData(address)", asset),
            abi.encode(
                address(0), // numeraire
                TIMELOCK, // timelock
                address(0), // governance
                address(0), // liquidityMigrator
                address(0), // poolInitializer
                address(0), // pool
                address(0), // migrationPool
                uint256(0), // numTokensToSell
                uint256(0), // totalSupply
                address(0) // integrator
            )
        );
    }

    function _generateInitData() internal {
        isToken0 = vm.randomBool();
        isUsingETH = vm.randomBool();

        if (isUsingETH) {
            currency0 = Currency.wrap(address(0));
            asset = Currency.unwrap(currency1);
            numeraire = address(0);
            isToken0 = false;
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
