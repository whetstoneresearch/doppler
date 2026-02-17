// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { IPoolManager, PoolManager } from "@v4-core/PoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { Test } from "forge-std/Test.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionTestCompat } from "test/shared/OpeningAuctionTestCompat.sol";
import { AuctionPhase, AuctionPosition, OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";
import { AddressSet, LibAddressSet } from "test/invariant/AddressSet.sol";

using PoolIdLibrary for PoolKey;
using StateLibrary for IPoolManager;
using LibAddressSet for AddressSet;

// ============ OpeningAuction Implementation ============

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionImpl is OpeningAuctionTestCompat {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuctionTestCompat(poolManager_, initializer_, totalAuctionTokens_, config_) { }

    function validateHookAddress(BaseHook) internal pure override { }

    /// @notice Expose activeTicks for testing - walks the bitmap to return all active ticks
    function getActiveTicks() external view returns (int24[] memory) {
        if (!hasActiveTicks) return new int24[](0);
        
        // First pass: count active ticks
        uint256 count = activeTickCount;
        int24[] memory ticks = new int24[](count);
        
        // Second pass: collect ticks by walking bitmap
        uint256 idx = 0;
        int24 iterTick = minActiveTick;
        while (iterTick <= maxActiveTick && idx < count) {
            (int24 nextCompressed, bool found) = _nextInitializedTick(iterTick - 1, false, maxActiveTick + 1);
            if (!found || nextCompressed > maxActiveTick) break;
            ticks[idx++] = _decompressTick(nextCompressed);
            iterTick = nextCompressed + 1;
        }
        
        return ticks;
    }

    /// @notice Get the number of active ticks
    function getActiveTicksLength() external view returns (uint256) {
        return activeTickCount;
    }
    
    /// @notice Expose hasActiveTicks for testing
    function getHasActiveTicks() external view returns (bool) {
        return hasActiveTicks;
    }
    
    /// @notice Expose min/max active ticks for testing
    function getActiveTickBounds() external view returns (int24 minTick, int24 maxTick) {
        if (!hasActiveTicks) return (0, 0);
        return (_decompressTick(minActiveTick), _decompressTick(maxActiveTick));
    }

    function isTickActive(int24 tick) external view returns (bool) {
        return _isCompressedTickActive(_compressTick(tick));
    }

    function getTickRewardDebtSumX128(int24 tick) external view returns (uint256) {
        return tickRewardDebtSumX128[tick];
    }
}

// ============ Handler Contract ============

/// @title OpeningAuctionHandler
/// @notice Handler contract for fuzzing OpeningAuction operations
/// @dev Performs random operations and tracks ghost variables for invariant checking
contract OpeningAuctionHandler is Test {
    // ============ State Variables ============

    OpeningAuctionImpl public hook;
    IPoolManager public manager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolKey public poolKey;
    bool public isToken0;

    TestERC20 public token0;
    TestERC20 public token1;

    // ============ Ghost Variables ============

    /// @notice Total incentives claimed by all positions
    uint256 public ghost_totalIncentivesClaimed;

    /// @notice Mapping of position ID to whether it has claimed
    mapping(uint256 => bool) public ghost_positionHasClaimed;

    /// @notice Track all position IDs created
    uint256[] public ghost_allPositionIds;

    /// @notice Track accumulators at each observation for monotonicity checks
    mapping(int24 => uint256) public ghost_lastAccumulatorValue;

    /// @notice Track earned time at each observation for monotonicity checks
    mapping(uint256 => uint256) public ghost_lastEarnedTime;

    /// @notice Track whether auction has been settled
    bool public ghost_isSettled;

    /// @notice Track whether auction has been migrated
    bool public ghost_isMigrated;

    /// @notice Track whether incentives were swept
    bool public ghost_hasSwept;

    /// @notice Track whether incentives were recovered
    bool public ghost_hasRecovered;

    /// @notice Track if any in-range position was removed successfully
    bool public ghost_removedInRange;

    /// @notice Initializer address for migrate calls
    address public initializer;
    /// @notice Track claimable amounts at settlement (frozen values)
    mapping(uint256 => uint256) public ghost_claimableAtSettlement;

    /// @notice Count of operations for debugging
    uint256 public ghost_addBidCount;
    uint256 public ghost_removeBidCount;
    uint256 public ghost_warpCount;
    uint256 public ghost_settleCount;
    uint256 public ghost_claimCount;
    uint256 internal bidNonce;
    mapping(uint256 => bytes32) internal positionSalts;

    // ============ Actor Management ============

    AddressSet internal actors;
    address internal currentActor;

    /// @notice Mapping of actor to their position IDs
    mapping(address => uint256[]) public actorPositions;

    // ============ Constructor ============

    constructor(
        OpeningAuctionImpl hook_,
        IPoolManager manager_,
        PoolModifyLiquidityTest modifyLiquidityRouter_,
        PoolKey memory poolKey_,
        bool isToken0_,
        address initializer_
    ) {
        hook = hook_;
        manager = manager_;
        modifyLiquidityRouter = modifyLiquidityRouter_;
        poolKey = poolKey_;
        isToken0 = isToken0_;
        initializer = initializer_;

        token0 = TestERC20(Currency.unwrap(poolKey_.currency0));
        token1 = TestERC20(Currency.unwrap(poolKey_.currency1));
    }

    // ============ Handler Functions ============

    /// @notice Add a bid at a random tick with random liquidity
    /// @param tickSeed Seed for tick selection
    /// @param liquiditySeed Seed for liquidity amount
    function addBid(uint256 tickSeed, uint256 liquiditySeed) external {
        // Only add bids during active auction
        if (hook.phase() != AuctionPhase.Active) return;
        if (block.timestamp >= hook.auctionEndTime()) return;

        currentActor = msg.sender;
        actors.add(msg.sender);

        ghost_addBidCount++;

        // Calculate tick parameters
        int24 tickLower = _calculateValidTick(tickSeed);
        if (tickLower == type(int24).min) return; // Invalid tick range

        // Generate liquidity above minimum
        uint128 minLiq = hook.minLiquidity();
        uint128 liquidity = minLiq + uint128(liquiditySeed % 10 ether);

        // Fund and approve
        _fundActor(currentActor);

        bytes32 salt = keccak256(abi.encode(currentActor, bidNonce++));

        // Try to add the bid
        vm.startPrank(currentActor);
        try modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + poolKey.tickSpacing,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            abi.encodePacked(currentActor)
        ) {
            uint256 positionId = hook.getPositionId(currentActor, tickLower, tickLower + poolKey.tickSpacing, salt);
            ghost_allPositionIds.push(positionId);
            actorPositions[currentActor].push(positionId);
            positionSalts[positionId] = salt;
        } catch {
            // Bid failed - expected for some random inputs
        }
        vm.stopPrank();
    }

    /// @notice Remove a bid (only if not locked)
    /// @param positionSeed Seed for selecting which position to remove
    function removeBid(uint256 positionSeed) external {
        // Only remove during active auction
        if (hook.phase() != AuctionPhase.Active) return;

        currentActor = actors.rand(positionSeed);
        if (currentActor == address(0)) return;

        uint256[] storage positions = actorPositions[currentActor];
        if (positions.length == 0) return;

        ghost_removeBidCount++;

        uint256 idx = positionSeed % positions.length;
        uint256 positionId = positions[idx];

        AuctionPosition memory pos = hook.positions(positionId);
        if (pos.owner == address(0) || pos.liquidity == 0) return;
        if (hook.isInRange(positionId)) return;

        vm.startPrank(currentActor);
        try modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: positionSalts[positionId]
            }),
            abi.encodePacked(currentActor)
        ) {
        // Position removed successfully
        }
            catch {
            // Removal failed
        }
        vm.stopPrank();
    }

    /// @notice Warp time forward
    /// @param timeSeed Seed for time warp amount
    function warpTime(uint256 timeSeed) external {
        ghost_warpCount++;

        uint256 warpAmount = 1 + (timeSeed % 3600);
        vm.warp(block.timestamp + warpAmount);

        _recordAccumulators();
        _recordEarnedTimes();
    }

    /// @notice Settle the auction after it ends
    function settleAuction() external {
        if (hook.phase() != AuctionPhase.Active) return;
        if (block.timestamp < hook.auctionEndTime()) return;

        ghost_settleCount++;

        // Record claimable amounts before settlement
        _recordClaimableAmounts();

        try hook.settleAuction() {
            ghost_isSettled = true;
        } catch {
            // Settlement failed
        }
    }

    /// @notice Claim incentives for a position
    /// @param positionSeed Seed for selecting which position to claim
    function claimIncentives(uint256 positionSeed) external {
        if (hook.phase() != AuctionPhase.Settled) return;
        if (ghost_allPositionIds.length == 0) return;

        ghost_claimCount++;

        uint256 idx = positionSeed % ghost_allPositionIds.length;
        uint256 positionId = ghost_allPositionIds[idx];

        if (ghost_positionHasClaimed[positionId]) return;

        AuctionPosition memory pos = hook.positions(positionId);
        if (pos.owner == address(0)) return;
        if (pos.hasClaimedIncentives) return;

        uint256 incentiveAmount = hook.calculateIncentives(positionId);

        if (!hook.isMigrated()) {
            vm.prank(initializer);
            try hook.migrate(address(this)) {
                ghost_isMigrated = true;
            } catch {
                return;
            }
        }

        try hook.claimIncentives(positionId) {
            ghost_totalIncentivesClaimed += incentiveAmount;
            ghost_positionHasClaimed[positionId] = true;
        } catch {
            // Claim failed
        }
    }

    /// @notice Attempt to remove an in-range position (should revert)
    /// @param positionSeed Seed for selecting which position to remove
    function tryRemoveInRange(uint256 positionSeed) external {
        if (hook.phase() != AuctionPhase.Active) return;
        if (ghost_removedInRange) return;

        currentActor = actors.rand(positionSeed);
        if (currentActor == address(0)) return;

        uint256[] storage positions = actorPositions[currentActor];
        if (positions.length == 0) return;

        uint256 idx = positionSeed % positions.length;
        uint256 positionId = positions[idx];

        AuctionPosition memory pos = hook.positions(positionId);
        if (pos.owner == address(0) || pos.liquidity == 0) return;
        if (!hook.isInRange(positionId)) return;

        vm.startPrank(currentActor);
        try modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: positionSalts[positionId]
            }),
            abi.encodePacked(currentActor)
        ) {
            ghost_removedInRange = true;
        } catch {
            // Expected to revert
        }
        vm.stopPrank();
    }

    /// @notice Sweep unclaimed incentives after the claim window
    function sweepUnclaimedIncentives() external {
        if (hook.phase() != AuctionPhase.Settled) return;
        if (block.timestamp <= hook.incentivesClaimDeadline()) return;
        if (ghost_hasSwept) return;

        if (!hook.isMigrated()) {
            vm.prank(initializer);
            try hook.migrate(address(this)) {
                ghost_isMigrated = true;
            } catch {
                return;
            }
        }

        vm.prank(initializer);
        try hook.sweepUnclaimedIncentives(initializer) {
            ghost_hasSwept = true;
        } catch {
            // Sweep failed
        }
    }

    /// @notice Recover incentives when no positions earned time
    function recoverIncentives() external {
        if (hook.phase() != AuctionPhase.Settled) return;
        if (ghost_hasRecovered) return;
        if (hook.cachedTotalWeightedTimeX128() > 0) return;
        if (hook.incentiveTokensTotal() == 0) return;

        if (!hook.isMigrated()) {
            vm.prank(initializer);
            try hook.migrate(address(this)) {
                ghost_isMigrated = true;
            } catch {
                return;
            }
        }

        vm.prank(initializer);
        try hook.recoverIncentives(initializer) {
            ghost_hasRecovered = true;
        } catch {
            // Recovery failed
        }
    }

    /// @notice Force warp to auction end for testing settlement
    function warpToAuctionEnd() external {
        if (hook.phase() == AuctionPhase.Active) {
            vm.warp(hook.auctionEndTime() + 1);
            _recordAccumulators();
            _recordEarnedTimes();
        }
    }

    // ============ Internal Functions ============

    /// @notice Calculate a valid tick for bidding
    function _calculateValidTick(uint256 seed) internal view returns (int24) {
        int24 tickSpacing = poolKey.tickSpacing;
        int24 minTick = hook.minAcceptableTick();
        int24 maxTick = alignTickTowardZero(TickMath.MAX_TICK, tickSpacing);

        if (isToken0) {
            int24 tickRange = maxTick - minTick;
            if (tickRange <= 0) return type(int24).min;

            int24 tickLower = minTick + int24(int256(seed % uint256(int256(tickRange))));
            tickLower = (tickLower / tickSpacing) * tickSpacing;
            if (tickLower < minTick) tickLower = ((minTick / tickSpacing) + 1) * tickSpacing;
            return tickLower;
        } else {
            int24 minValidTick = alignTickTowardZero(TickMath.MIN_TICK, tickSpacing);
            int24 tickRange = minTick - minValidTick;
            if (tickRange <= 0) return type(int24).min;

            int24 tickLower = minValidTick + int24(int256(seed % uint256(int256(tickRange))));
            tickLower = (tickLower / tickSpacing) * tickSpacing;
            int24 maxAllowedTick = minTick - tickSpacing;
            if (tickLower > maxAllowedTick) tickLower = (maxAllowedTick / tickSpacing) * tickSpacing;
            return tickLower;
        }
    }

    /// @notice Fund an actor with tokens
    function _fundActor(address actor) internal {
        token0.mint(actor, 100 ether);
        token1.mint(actor, 100 ether);
        vm.startPrank(actor);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Record current accumulator values for all active ticks
    function _recordAccumulators() internal {
        int24[] memory ticks = hook.getActiveTicks();
        for (uint256 i = 0; i < ticks.length; i++) {
            int24 tick = ticks[i];
            (, uint256 accum,) = hook.tickTimeStates(tick);
            ghost_lastAccumulatorValue[tick] = accum;
        }
    }

    /// @notice Record current earned times for all positions
    function _recordEarnedTimes() internal {
        for (uint256 i = 0; i < ghost_allPositionIds.length; i++) {
            uint256 posId = ghost_allPositionIds[i];
            AuctionPosition memory pos = hook.positions(posId);
            if (pos.owner != address(0) && !pos.hasClaimedIncentives) {
                ghost_lastEarnedTime[posId] = hook.getPositionAccumulatedTime(posId);
            }
        }
    }

    /// @notice Record claimable amounts at settlement
    function _recordClaimableAmounts() internal {
        for (uint256 i = 0; i < ghost_allPositionIds.length; i++) {
            uint256 posId = ghost_allPositionIds[i];
            ghost_claimableAtSettlement[posId] = hook.calculateIncentives(posId);
        }
    }

    // ============ View Functions ============

    function getPositionCount() external view returns (uint256) {
        return ghost_allPositionIds.length;
    }

    function getPositionIdAt(uint256 index) external view returns (uint256) {
        return ghost_allPositionIds[index];
    }

    function getLastAccumulatorValue(int24 tick) external view returns (uint256) {
        return ghost_lastAccumulatorValue[tick];
    }

    function getLastEarnedTime(uint256 positionId) external view returns (uint256) {
        return ghost_lastEarnedTime[positionId];
    }

    function getClaimableAtSettlement(uint256 positionId) external view returns (uint256) {
        return ghost_claimableAtSettlement[positionId];
    }
}

// ============ Invariant Test Contract ============

/// @title OpeningAuctionInvariantsTest
/// @notice Invariant tests for OpeningAuction incentives mechanism
/// @dev Tests the following invariants:
///      1. Conservation: Sum of all claimed incentives ≤ incentiveTokensTotal
///      2. Monotonic Accumulators: accumulatedSecondsX128 never decreases
///      3. Monotonic Earned Time: Position earned time never decreases (until claimed)
///      4. Settlement Finality: After settlement, claimable amounts are frozen
///      5. No Double Claim: Cannot claim same position twice
contract OpeningAuctionInvariantsTest is Test, Deployers {
    // ============ Constants ============

    uint256 constant DEFAULT_AUCTION_TOKENS = 100 ether;
    uint256 constant DEFAULT_AUCTION_DURATION = 1 days;
    int24 constant DEFAULT_MIN_ACCEPTABLE_TICK = -34_020;
    uint256 constant DEFAULT_INCENTIVE_SHARE_BPS = 1000;
    int24 constant DEFAULT_TICK_SPACING = 60;
    uint24 constant DEFAULT_FEE = 3000;
    uint128 constant DEFAULT_MIN_LIQUIDITY = 1e15;

    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    // ============ State Variables ============

    OpeningAuctionImpl hook;
    OpeningAuctionHandler handler;

    address asset;
    address numeraire;
    address token0;
    address token1;
    PoolId poolId;
    bool isToken0;

    address initializer = address(0xbeef);

    // ============ Setup ============

    function setUp() public {
        manager = new PoolManager(address(this));

        isToken0 = true;

        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = isToken0 ? TOKEN_A : TOKEN_B;
        numeraire = isToken0 ? TOKEN_B : TOKEN_A;
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        vm.label(token0, "Token0");
        vm.label(token1, "Token1");

        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");

        _deployOpeningAuction();

        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);

        handler = new OpeningAuctionHandler(hook, manager, modifyLiquidityRouter, key, isToken0, initializer);
        vm.label(address(handler), "Handler");

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.addBid.selector;
        selectors[1] = handler.removeBid.selector;
        selectors[2] = handler.warpTime.selector;
        selectors[3] = handler.settleAuction.selector;
        selectors[4] = handler.claimIncentives.selector;
        selectors[5] = handler.warpToAuctionEnd.selector;
        selectors[6] = handler.tryRemoveInRange.selector;
        selectors[7] = handler.sweepUnclaimedIncentives.selector;
        selectors[8] = handler.recoverIncentives.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        excludeSender(address(0));
        excludeSender(address(this));
        excludeSender(address(handler));
        excludeSender(address(hook));
        excludeSender(address(token0));
        excludeSender(address(token1));
        excludeSender(address(manager));
        excludeSender(address(modifyLiquidityRouter));
        excludeSender(initializer);
    }

    function _getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG
        );
    }

    function _deployOpeningAuction() internal {
        OpeningAuctionConfig memory config = OpeningAuctionConfig({
            auctionDuration: DEFAULT_AUCTION_DURATION,
            minAcceptableTickToken0: DEFAULT_MIN_ACCEPTABLE_TICK,
            minAcceptableTickToken1: DEFAULT_MIN_ACCEPTABLE_TICK,
            incentiveShareBps: DEFAULT_INCENTIVE_SHARE_BPS,
            tickSpacing: DEFAULT_TICK_SPACING,
            fee: DEFAULT_FEE,
            minLiquidity: DEFAULT_MIN_LIQUIDITY,
            shareToAuctionBps: 10_000
        });

        address hookAddress = address(uint160(_getHookFlags()) ^ (0x4444 << 144));

        deployCodeTo(
            "OpeningAuctionInvariants.t.sol:OpeningAuctionImpl",
            abi.encode(manager, initializer, DEFAULT_AUCTION_TOKENS, config),
            hookAddress
        );

        hook = OpeningAuctionImpl(payable(hookAddress));
        vm.label(address(hook), "OpeningAuction");

        TestERC20(asset).transfer(address(hook), DEFAULT_AUCTION_TOKENS);

        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });

        poolId = key.toId();

        vm.startPrank(initializer);
        hook.setPositionManager(address(modifyLiquidityRouter));
        hook.setIsToken0(isToken0);
        vm.stopPrank();

        int24 startingTick = alignTickTowardZero(isToken0 ? TickMath.MAX_TICK : TickMath.MIN_TICK, config.tickSpacing);

        vm.prank(initializer);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(startingTick));
    }

    // ============ Invariant Tests ============

    /// @notice INVARIANT 1: Conservation - Sum of claimed incentives ≤ incentiveTokensTotal
    /// @dev Total incentives claimed must never exceed allocated incentive tokens
    function invariant_conservation_claimedIncentivesLeTotal() public view {
        uint256 totalIncentives = hook.incentiveTokensTotal();
        uint256 totalClaimed = handler.ghost_totalIncentivesClaimed();

        assertLe(totalClaimed, totalIncentives, "Conservation: claimed > total incentives");
    }

    /// @notice INVARIANT 2: Monotonic Accumulators - accumulatedSecondsX128 never decreases
    /// @dev Tick accumulators should only increase over time
    function invariant_monotonic_accumulators() public view {
        int24[] memory activeTicks = hook.getActiveTicks();

        for (uint256 i = 0; i < activeTicks.length; i++) {
            int24 tick = activeTicks[i];
            (, uint256 currentAccum,) = hook.tickTimeStates(tick);
            uint256 lastAccum = handler.getLastAccumulatorValue(tick);

            if (lastAccum > 0) {
                assertGe(currentAccum, lastAccum, "Monotonic: accumulator decreased");
            }
        }
    }

    /// @notice INVARIANT 3: Monotonic Earned Time - Position earned time never decreases
    /// @dev Position's earned time should only increase (until claimed)
    function invariant_monotonic_earned_time() public view {
        uint256 positionCount = handler.getPositionCount();

        for (uint256 i = 0; i < positionCount; i++) {
            uint256 posId = handler.getPositionIdAt(i);
            AuctionPosition memory pos = hook.positions(posId);

            if (pos.hasClaimedIncentives || pos.owner == address(0)) continue;

            uint256 currentEarnedTime = hook.getPositionAccumulatedTime(posId);
            uint256 lastEarnedTime = handler.getLastEarnedTime(posId);

            if (lastEarnedTime > 0) {
                assertGe(currentEarnedTime, lastEarnedTime, "Monotonic: earned time decreased");
            }
        }
    }

    /// @notice INVARIANT 4: Settlement Finality - Claimable amounts frozen after settlement
    /// @dev Once settled, incentive calculations should be deterministic
    function invariant_settlement_finality() public view {
        if (!handler.ghost_isSettled()) return;
        if (hook.phase() != AuctionPhase.Settled) return;

        uint256 positionCount = handler.getPositionCount();

        for (uint256 i = 0; i < positionCount; i++) {
            uint256 posId = handler.getPositionIdAt(i);
            AuctionPosition memory pos = hook.positions(posId);

            if (pos.hasClaimedIncentives || pos.owner == address(0)) continue;

            uint256 claimableNow = hook.calculateIncentives(posId);
            uint256 claimableAtSettlement = handler.getClaimableAtSettlement(posId);

            assertApproxEqAbs(claimableNow, claimableAtSettlement, 1, "Finality: claimable changed post-settlement");
        }
    }

    /// @notice INVARIANT 5: No Double Claim - Cannot claim same position twice
    /// @dev Claimed positions should have hasClaimedIncentives=true and return 0 incentives
    function invariant_no_double_claim() public view {
        uint256 positionCount = handler.getPositionCount();

        for (uint256 i = 0; i < positionCount; i++) {
            uint256 posId = handler.getPositionIdAt(i);

            if (handler.ghost_positionHasClaimed(posId)) {
                AuctionPosition memory pos = hook.positions(posId);

                assertTrue(pos.hasClaimedIncentives, "Double claim: flag not set after claim");

                uint256 incentives = hook.calculateIncentives(posId);
                assertEq(incentives, 0, "Double claim: non-zero incentives after claim");
            }
        }
    }

    /// @notice Additional: After migration, reserved balance matches incentive accounting
    function invariant_reserved_balance_matches_accounting() public view {
        if (!hook.isMigrated()) return;

        (Currency currency0, Currency currency1,,,) = hook.poolKey();
        Currency assetCurrency = hook.isToken0() ? currency0 : currency1;
        uint256 balance = TestERC20(Currency.unwrap(assetCurrency)).balanceOf(address(hook));

        uint256 reserved = hook.incentiveTokensTotal() - hook.totalIncentivesClaimed();
        assertEq(balance, reserved, "Reserved balance mismatch");
    }

    /// @notice Additional: Removing in-range liquidity should never succeed
    function invariant_no_in_range_removals() public view {
        assertFalse(handler.ghost_removedInRange(), "In-range removal succeeded");
    }

    /// @notice Additional: Ticks with liquidity are always active and counted
    function invariant_active_ticks_match_positions() public view {
        uint256 positionCount = handler.getPositionCount();
        int24[] memory uniqueTicks = new int24[](positionCount);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < positionCount; i++) {
            uint256 posId = handler.getPositionIdAt(i);
            AuctionPosition memory pos = hook.positions(posId);

            if (pos.owner == address(0) || pos.liquidity == 0) continue;

            bool seen = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueTicks[j] == pos.tickLower) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                uniqueTicks[uniqueCount++] = pos.tickLower;
                assertTrue(hook.isTickActive(pos.tickLower), "Tick with liquidity not active");
            }
        }

        assertEq(uniqueCount, hook.getActiveTicksLength(), "Active tick count mismatch");
    }

    /// @notice Additional: sweep/recover set expected accounting state
    function invariant_sweep_recover_accounting() public view {
        if (handler.ghost_hasSwept()) {
            assertEq(
                hook.incentiveTokensTotal(),
                hook.totalIncentivesClaimed(),
                "Sweep should zero remaining incentives"
            );
        }

        if (handler.ghost_hasRecovered()) {
            assertEq(hook.incentiveTokensTotal(), 0, "Recover should zero incentives");
        }
    }

    /// @notice Additional: Total pending + claimed ≤ incentiveTokensTotal
    /// @dev Sum of all incentives (claimed and pending) must not exceed total
    function invariant_total_incentives_bounded() public view {
        uint256 positionCount = handler.getPositionCount();
        if (positionCount == 0) return;

        uint256 totalPending = 0;
        for (uint256 i = 0; i < positionCount; i++) {
            uint256 posId = handler.getPositionIdAt(i);
            AuctionPosition memory pos = hook.positions(posId);

            if (!pos.hasClaimedIncentives && pos.owner != address(0)) {
                totalPending += hook.calculateIncentives(posId);
            }
        }

        uint256 totalIncentives = hook.incentiveTokensTotal();
        uint256 totalClaimed = handler.ghost_totalIncentivesClaimed();

        assertLe(totalPending + totalClaimed, totalIncentives + 1, "Bounded: pending + claimed > total");
    }

    /// @notice Additional: Active ticks have non-zero liquidity
    /// @dev Every tick in activeTicks array should have liquidity > 0
    function invariant_active_ticks_have_liquidity() public view {
        int24[] memory activeTicks = hook.getActiveTicks();

        for (uint256 i = 0; i < activeTicks.length; i++) {
            int24 tick = activeTicks[i];
            uint128 liquidity = hook.liquidityAtTick(tick);

            assertGt(liquidity, 0, "Active tick: zero liquidity");
        }
    }

    /// @notice Additional: Active tick metadata matches derived values
    function invariant_active_tick_metadata_consistent() public view {
        int24[] memory activeTicks = hook.getActiveTicks();
        uint256 count = activeTicks.length;

        assertEq(count, hook.getActiveTicksLength(), "Active tick count mismatch");
        assertEq(hook.getHasActiveTicks(), count > 0, "hasActiveTicks mismatch");

        if (count > 0) {
            int24 minTick = activeTicks[0];
            int24 maxTick = activeTicks[0];

            for (uint256 i = 1; i < count; i++) {
                int24 tick = activeTicks[i];
                if (tick < minTick) minTick = tick;
                if (tick > maxTick) maxTick = tick;
            }

            (int24 boundMin, int24 boundMax) = hook.getActiveTickBounds();
            assertEq(boundMin, minTick, "Min active tick mismatch");
            assertEq(boundMax, maxTick, "Max active tick mismatch");
        }
    }

    /// @notice Additional: Positions see their ticks as active
    function invariant_positions_on_active_ticks() public view {
        uint256 positionCount = handler.getPositionCount();

        for (uint256 i = 0; i < positionCount; i++) {
            uint256 posId = handler.getPositionIdAt(i);
            AuctionPosition memory pos = hook.positions(posId);

            if (pos.owner == address(0) || pos.liquidity == 0) continue;

            assertTrue(hook.isTickActive(pos.tickLower), "Position tick not active");
        }
    }

    /// @notice Additional: liquidityAtTick equals sum of live position liquidity at each active tick
    function invariant_liquidityAtTick_matches_positions() public view {
        int24[] memory activeTicks = hook.getActiveTicks();
        uint256 positionCount = handler.getPositionCount();

        for (uint256 i = 0; i < activeTicks.length; i++) {
            int24 tick = activeTicks[i];
            uint256 sumLiquidity = 0;

            for (uint256 j = 0; j < positionCount; j++) {
                uint256 posId = handler.getPositionIdAt(j);
                AuctionPosition memory pos = hook.positions(posId);

                if (pos.owner == address(0) || pos.liquidity == 0) continue;
                if (pos.tickLower != tick) continue;

                sumLiquidity += pos.liquidity;
            }

            assertEq(sumLiquidity, hook.liquidityAtTick(tick), "Liquidity sum mismatch");
        }
    }

    /// @notice Additional: Reward debt sum per tick matches active positions
    function invariant_reward_debt_sum_matches_positions() public view {
        int24[] memory activeTicks = hook.getActiveTicks();
        uint256 positionCount = handler.getPositionCount();

        for (uint256 i = 0; i < activeTicks.length; i++) {
            int24 tick = activeTicks[i];
            uint256 sumRewardDebt = 0;

            for (uint256 j = 0; j < positionCount; j++) {
                uint256 posId = handler.getPositionIdAt(j);
                AuctionPosition memory pos = hook.positions(posId);

                if (pos.owner == address(0) || pos.liquidity == 0) continue;
                if (pos.tickLower != tick) continue;

                sumRewardDebt += pos.rewardDebtX128 * uint256(pos.liquidity);
            }

            assertEq(sumRewardDebt, hook.getTickRewardDebtSumX128(tick), "Reward debt sum mismatch");
        }
    }

    /// @notice Additional: Total harvested time equals sum of per-position harvested time
    function invariant_total_harvested_time_matches_positions() public view {
        uint256 positionCount = handler.getPositionCount();
        uint256 totalHarvested = 0;

        for (uint256 i = 0; i < positionCount; i++) {
            uint256 posId = handler.getPositionIdAt(i);
            totalHarvested += hook.positionHarvestedTimeX128(posId);
        }

        assertEq(totalHarvested, hook.totalHarvestedTimeX128(), "Harvested time mismatch");
    }

    /// @notice Sanity check that handler is working
    function invariant_handler_tracking() public view {
        assertTrue(address(handler) != address(0), "Handler accessible");
    }
}
