// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC721 } from "@solmate/tokens/ERC721.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { UniswapV4MigratorSplit, ZeroLiquidity } from "src/migrators/UniswapV4MigratorSplit.sol";
import { UniswapV4MigratorSplitHook } from "src/migrators/UniswapV4MigratorSplitHook.sol";
import {
    BeneficiaryData,
    InvalidProtocolOwnerBeneficiary,
    InvalidProtocolOwnerShares,
    InvalidShares,
    InvalidTotalShares,
    MIN_PROTOCOL_OWNER_SHARES,
    UnorderedBeneficiaries
} from "src/types/BeneficiaryData.sol";
// We don't use the `PositionDescriptor` contract explictly here but importing it ensures it gets compiled
import { PosmTestSetup } from "@v4-periphery-test/shared/PosmTestSetup.sol";
import { PositionDescriptor } from "@v4-periphery/PositionDescriptor.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";

contract MockAirlock {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

contract UniswapV4MigratorTest is PosmTestSetup {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockAirlock public airlock;
    address public protocolOwner = address(0xb055);

    UniswapV4MigratorSplit public migrator;
    UniswapV4MigratorSplitHook public migratorHook;
    StreamableFeesLockerV2 public locker;
    TopUpDistributor public topUpDistributor;

    address public asset;
    address public numeraire;
    address public token0;
    address public token1;

    address constant BENEFICIARY_1 = address(0x1111);
    address constant BENEFICIARY_2 = address(0x2222);
    address constant BENEFICIARY_3 = address(0x3333);
    address constant RECIPIENT = address(0x4444);
    address constant PROCEEDS_RECIPIENT = address(0x5555);

    int24 constant TICK_SPACING = 8;
    uint24 constant FEE = 3000;
    uint32 constant LOCK_DURATION = 30 days;
    uint256 constant PROCEEDS_SHARE = 0.0; // 10%
    uint256 constant SPLIT_SHARE = 0.1e18;
    uint160 constant SQRT_PRICE_X96 = 6_786_529_797_232_128_452_535_845;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployPosm(manager);

        airlock = new MockAirlock(protocolOwner);
        migratorHook = UniswapV4MigratorSplitHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        locker = new StreamableFeesLockerV2(manager, protocolOwner);
        topUpDistributor = new TopUpDistributor(address(airlock));
        migrator = new UniswapV4MigratorSplit(
            address(airlock),
            IPoolManager(manager),
            PositionManager(payable(address(lpm))),
            locker,
            IHooks(migratorHook),
            topUpDistributor
        );
        vm.prank(protocolOwner);
        locker.approveMigrator(address(migrator));
        deployCodeTo("UniswapV4MigratorSplitHook", abi.encode(manager, migrator), address(migratorHook));

        vm.prank(protocolOwner);
        topUpDistributor.setPullUp(address(migrator), true);
    }

    function _setUpTokens() internal {
        asset = address(new TestERC20(0));
        numeraire = address(new TestERC20(0));
        token0 = address(asset);
        token1 = address(numeraire);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        vm.label(token0, "Token0");
        vm.label(token1, "Token1");
    }

    function _defaultBeneficiaries() internal view returns (BeneficiaryData[] memory beneficiaries) {
        beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });
    }

    function _initializeMigrator(address proceedsRecipient, uint256 proceedsShare) internal {
        vm.startPrank(address(airlock));
        migrator.initialize(
            asset,
            numeraire,
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, _defaultBeneficiaries(), proceedsRecipient, proceedsShare)
        );
        vm.stopPrank();
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        return token == address(0) ? account.balance : TestERC20(token).balanceOf(account);
    }

    function _assertNoDust(address account) internal view {
        assertEq(_balanceOf(token0, account), 0, "Unexpected token0 dust");
        assertEq(_balanceOf(token1, account), 0, "Unexpected token1 dust");
    }

    function _expectedMigratedLiquidity(PoolKey memory poolKey, uint256 balance0, uint256 balance1)
        internal
        view
        returns (
            int24 lowerTick,
            int24 upperTick,
            int24 currentTick,
            uint128 belowPriceLiquidity,
            uint128 abovePriceLiquidity
        )
    {
        PoolId poolId = poolKey.toId();

        lowerTick = TickMath.minUsableTick(poolKey.tickSpacing);
        upperTick = TickMath.maxUsableTick(poolKey.tickSpacing);

        (, currentTick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        currentTick = currentTick / poolKey.tickSpacing * poolKey.tickSpacing;

        belowPriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(lowerTick),
            TickMath.getSqrtPriceAtTick(currentTick - poolKey.tickSpacing),
            0,
            balance1 == 0 ? 0 : uint128(balance1) - 1
        );

        abovePriceLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(currentTick + poolKey.tickSpacing),
            TickMath.getSqrtPriceAtTick(upperTick),
            balance0 == 0 ? 0 : uint128(balance0) - 1,
            0
        );
    }

    function test_initialize_StoresPoolKey() public {
        _setUpTokens();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );

        (PoolKey memory poolKey, uint256 lockDuration) = migrator.getAssetData(token0, token1);
        assertEq(Currency.unwrap(poolKey.currency0), token0);
        assertEq(Currency.unwrap(poolKey.currency1), token1);
        assertEq(poolKey.fee, FEE);
        assertEq(poolKey.tickSpacing, TICK_SPACING);
        assertEq(address(poolKey.hooks), address(migratorHook));
        assertEq(lockDuration, LOCK_DURATION);
    }

    function test_initialize_StoresSplitConfiguration() public {
        _setUpTokens();

        _initializeMigrator(PROCEEDS_RECIPIENT, SPLIT_SHARE);

        (address splitRecipient, bool isToken0, uint256 share) = migrator.splitConfigurationOf(token0, token1);
        assertEq(splitRecipient, PROCEEDS_RECIPIENT);
        assertEq(share, SPLIT_SHARE);
        assertEq(isToken0, asset < numeraire);
    }

    /// forge-config: default.fuzz.runs = 512
    function test_migrate(bool isUsingETH, bool hasRecipient, uint64 balance0, uint64 balance1) public {
        vm.assume(balance0 > 1e18 && balance1 > 1e18);
        _setUpTokens();

        if (isUsingETH) {
            asset = numeraire;
            token1 = asset;
            token0 = address(0);
            numeraire = address(0);
        }

        _initializeMigrator(PROCEEDS_RECIPIENT, PROCEEDS_SHARE);

        isUsingETH ? deal(address(migrator), balance0) : TestERC20(token0).mint(address(migrator), balance0);
        TestERC20(token1).mint(address(migrator), balance1);

        address recipient = hasRecipient ? RECIPIENT : address(0xdead);

        vm.prank(address(airlock));
        migrator.migrate(SQRT_PRICE_X96, token0, token1, recipient);

        (PoolKey memory poolKey,) = migrator.getAssetData(token0, token1);
        PoolId poolId = poolKey.toId();
        (, address streamRecipient, uint32 startDate, uint32 streamLockDuration, bool isUnlocked) =
            locker.streams(poolId);

        assertEq(streamRecipient, recipient, "Wrong stream recipient");
        assertEq(streamLockDuration, LOCK_DURATION, "Wrong stream lock duration");
        assertGt(startDate, 0, "Stream should be initialized");
        assertFalse(isUnlocked, "Stream should start locked");
        assertEq(locker.getShares(poolId, BENEFICIARY_1), 0.95e18, "Wrong beneficiary shares");
        assertEq(locker.getShares(poolId, airlock.owner()), 0.05e18, "Wrong protocol owner shares");

        if (recipient != address(0xdead)) {
            assertGe(ERC721(address(lpm)).balanceOf(address(recipient)), 1, "Wrong recipient balance");
        } else {
            assertEq(ERC721(address(lpm)).balanceOf(address(recipient)), 0, "No-op governance should not receive NFTs");
        }

        _assertNoDust(address(migrator));
        _assertNoDust(address(locker));
    }

    function test_migrate_LocksExpectedProtocolLiquidityAndLeavesNoLockerDust() public {
        _setUpTokens();
        _initializeMigrator(address(0), 0);

        uint256 balance0 = 10 ether;
        uint256 balance1 = 2 ether;
        TestERC20(token0).mint(address(migrator), balance0);
        TestERC20(token1).mint(address(migrator), balance1);

        vm.prank(address(airlock));
        uint256 liquidity = migrator.migrate(SQRT_PRICE_X96, token0, token1, RECIPIENT);

        (PoolKey memory poolKey,) = migrator.getAssetData(token0, token1);
        PoolId poolId = poolKey.toId();

        (
            int24 lowerTick,
            int24 upperTick,
            int24 currentTick,
            uint128 belowPriceLiquidity,
            uint128 abovePriceLiquidity
        ) = _expectedMigratedLiquidity(poolKey, balance0, balance1);

        assertEq(liquidity, uint256(belowPriceLiquidity) + uint256(abovePriceLiquidity), "Wrong total liquidity");

        (uint128 lockerBelowLiquidity,,) = IPoolManager(address(manager)).getPositionInfo(
            poolId, address(locker), lowerTick, currentTick - poolKey.tickSpacing, bytes32(0)
        );
        (uint128 lockerAboveLiquidity,,) = IPoolManager(address(manager)).getPositionInfo(
            poolId, address(locker), currentTick + poolKey.tickSpacing, upperTick, bytes32(0)
        );

        assertEq(lockerBelowLiquidity, belowPriceLiquidity / 10, "Wrong locked below-price liquidity");
        assertEq(lockerAboveLiquidity, abovePriceLiquidity / 10, "Wrong locked above-price liquidity");

        _assertNoDust(address(migrator));
        _assertNoDust(address(locker));
    }

    function test_migrate_NoOpGovernanceLocksAllLiquidityAndLeavesNoLockerDust() public {
        _setUpTokens();
        _initializeMigrator(address(0), 0);

        uint256 balance0 = 10 ether;
        uint256 balance1 = 2 ether;
        TestERC20(token0).mint(address(migrator), balance0);
        TestERC20(token1).mint(address(migrator), balance1);

        vm.prank(address(airlock));
        uint256 liquidity = migrator.migrate(SQRT_PRICE_X96, token0, token1, address(0xdead));

        (PoolKey memory poolKey,) = migrator.getAssetData(token0, token1);
        PoolId poolId = poolKey.toId();

        (
            int24 lowerTick,
            int24 upperTick,
            int24 currentTick,
            uint128 belowPriceLiquidity,
            uint128 abovePriceLiquidity
        ) = _expectedMigratedLiquidity(poolKey, balance0, balance1);

        assertEq(liquidity, uint256(belowPriceLiquidity) + uint256(abovePriceLiquidity), "Wrong total liquidity");

        (uint128 lockerBelowLiquidity,,) = IPoolManager(address(manager)).getPositionInfo(
            poolId, address(locker), lowerTick, currentTick - poolKey.tickSpacing, bytes32(0)
        );
        (uint128 lockerAboveLiquidity,,) = IPoolManager(address(manager)).getPositionInfo(
            poolId, address(locker), currentTick + poolKey.tickSpacing, upperTick, bytes32(0)
        );

        assertEq(lockerBelowLiquidity, belowPriceLiquidity, "Wrong no-op locked below-price liquidity");
        assertEq(lockerAboveLiquidity, abovePriceLiquidity, "Wrong no-op locked above-price liquidity");
        assertEq(ERC721(address(lpm)).balanceOf(address(0xdead)), 0, "No-op governance should not receive NFTs");

        _assertNoDust(address(migrator));
        _assertNoDust(address(locker));
    }

    function test_migrate_CollectFeesUnlocksMigratedStream() public {
        _setUpTokens();
        _initializeMigrator(PROCEEDS_RECIPIENT, PROCEEDS_SHARE);

        uint256 balance0 = 10 ether;
        uint256 balance1 = 2 ether;
        TestERC20(token0).mint(address(migrator), balance0);
        TestERC20(token1).mint(address(migrator), balance1);

        vm.prank(address(airlock));
        migrator.migrate(SQRT_PRICE_X96, token0, token1, RECIPIENT);

        (PoolKey memory poolKey,) = migrator.getAssetData(token0, token1);
        assertGe(ERC721(address(lpm)).balanceOf(RECIPIENT), 1, "Recipient should receive unlocked NFTs");

        uint256 recipientToken0BalanceBefore = TestERC20(token0).balanceOf(RECIPIENT);
        uint256 recipientToken1BalanceBefore = TestERC20(token1).balanceOf(RECIPIENT);

        vm.warp(block.timestamp + LOCK_DURATION + 1);
        locker.collectFees(poolKey.toId());

        (,,,, bool isUnlocked) = locker.streams(poolKey.toId());
        assertTrue(isUnlocked, "Stream should unlock after lock duration");
        assertGt(TestERC20(token0).balanceOf(RECIPIENT), recipientToken0BalanceBefore, "Recipient should receive token0");
        assertGt(TestERC20(token1).balanceOf(RECIPIENT), recipientToken1BalanceBefore, "Recipient should receive token1");
    }

    function test_migrate_NoOpGovernanceRemainsLockedAfterCollectFees() public {
        _setUpTokens();
        _initializeMigrator(PROCEEDS_RECIPIENT, PROCEEDS_SHARE);

        TestERC20(token0).mint(address(migrator), 10 ether);
        TestERC20(token1).mint(address(migrator), 2 ether);

        vm.prank(address(airlock));
        migrator.migrate(SQRT_PRICE_X96, token0, token1, address(0xdead));

        (PoolKey memory poolKey,) = migrator.getAssetData(token0, token1);

        vm.warp(block.timestamp + LOCK_DURATION + 1);
        locker.collectFees(poolKey.toId());

        (, address recipient,,, bool isUnlocked) = locker.streams(poolKey.toId());
        assertEq(recipient, address(0xdead), "Wrong no-op stream recipient");
        assertFalse(isUnlocked, "No-op governance stream should remain locked");
        assertEq(ERC721(address(lpm)).balanceOf(address(0xdead)), 0, "No-op governance should not receive NFTs");
    }

    function test_migrate_DistributesSplitToRecipient() public {
        _setUpTokens();
        _initializeMigrator(PROCEEDS_RECIPIENT, SPLIT_SHARE);

        uint256 balance0 = 10 ether;
        uint256 balance1 = 2 ether;
        TestERC20(token0).mint(address(migrator), balance0);
        TestERC20(token1).mint(address(migrator), balance1);

        uint256 proceedsRecipientBalance0Before = TestERC20(token0).balanceOf(PROCEEDS_RECIPIENT);
        uint256 proceedsRecipientBalance1Before = TestERC20(token1).balanceOf(PROCEEDS_RECIPIENT);

        vm.prank(address(airlock));
        migrator.migrate(SQRT_PRICE_X96, token0, token1, RECIPIENT);

        uint256 proceedsRecipientBalance0After = TestERC20(token0).balanceOf(PROCEEDS_RECIPIENT);
        uint256 proceedsRecipientBalance1After = TestERC20(token1).balanceOf(PROCEEDS_RECIPIENT);

        assertEq(
            proceedsRecipientBalance0After - proceedsRecipientBalance0Before,
            asset < numeraire ? 0 : balance0 * SPLIT_SHARE / 1e18,
            "Wrong token0 split distribution"
        );
        assertEq(
            proceedsRecipientBalance1After - proceedsRecipientBalance1Before,
            asset < numeraire ? balance1 * SPLIT_SHARE / 1e18 : 0,
            "Wrong token1 split distribution"
        );
    }

    function test_migrate_DoesNotDistributeSplitWhenDisabled() public {
        _setUpTokens();
        _initializeMigrator(address(0), 0);

        TestERC20(token0).mint(address(migrator), 10 ether);
        TestERC20(token1).mint(address(migrator), 2 ether);

        vm.prank(address(airlock));
        migrator.migrate(SQRT_PRICE_X96, token0, token1, RECIPIENT);

        assertEq(TestERC20(token0).balanceOf(PROCEEDS_RECIPIENT), 0, "Split recipient should not receive token0");
        assertEq(TestERC20(token1).balanceOf(PROCEEDS_RECIPIENT), 0, "Split recipient should not receive token1");
    }

    function test_migrate_DistributesSplitWithETH() public {
        _setUpTokens();

        asset = numeraire;
        token1 = asset;
        token0 = address(0);
        numeraire = address(0);

        _initializeMigrator(PROCEEDS_RECIPIENT, SPLIT_SHARE);

        uint256 ethBalance = 10 ether;
        uint256 tokenBalance = 2 ether;
        deal(address(migrator), ethBalance);
        TestERC20(token1).mint(address(migrator), tokenBalance);

        uint256 proceedsRecipientEthBefore = PROCEEDS_RECIPIENT.balance;

        vm.prank(address(airlock));
        migrator.migrate(SQRT_PRICE_X96, token0, token1, RECIPIENT);

        assertEq(PROCEEDS_RECIPIENT.balance - proceedsRecipientEthBefore, ethBalance * SPLIT_SHARE / 1e18, "Wrong ETH split");
    }

    function test_migrate_RevertsWhenZeroLiquidity() public {
        _setUpTokens();
        _initializeMigrator(PROCEEDS_RECIPIENT, PROCEEDS_SHARE);

        vm.prank(address(airlock));
        vm.expectRevert(ZeroLiquidity.selector);
        migrator.migrate(SQRT_PRICE_X96, token0, token1, RECIPIENT);
    }

    function test_initialize_RevertZeroAddressBeneficiary() public {
        _setUpTokens();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(UnorderedBeneficiaries.selector));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_RevertZeroShares() public {
        _setUpTokens();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidShares.selector));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_RevertIncorrectTotalShares() public {
        _setUpTokens();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.35e18 });
        beneficiaries[2] = BeneficiaryData({
            beneficiary: airlock.owner(),
            shares: 0.05e18 // Total is 0.9e18, not 1e18
        });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidTotalShares.selector));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_IncludesDopplerOwnerBeneficiary() public {
        _setUpTokens();

        // Set up beneficiaries without protocol owner
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.5e18 }); // 50%
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.4e18 }); // 40%
        beneficiaries[2] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.1e18 }); // 10%

        vm.prank(address(airlock));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_RevertInvalidProtocolOwnerShares() public {
        _setUpTokens();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.951e18 }); // 95.1%
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.049e18 }); // 4.9%

        vm.prank(address(airlock));
        vm.expectRevert(
            abi.encodeWithSelector(InvalidProtocolOwnerShares.selector, MIN_PROTOCOL_OWNER_SHARES, 0.049e18)
        );
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_RevertProtocolOwnerNotFound() public {
        _setUpTokens();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.4e18 }); // 40%
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.6e18 }); // 60%

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerBeneficiary.selector));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }
}
