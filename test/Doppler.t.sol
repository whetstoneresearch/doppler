// pragma solidity 0.8.26;

// import {Test} from "forge-std/Test.sol";
// import {console2} from "forge-std/console2.sol";

// import {Deployers} from "v4-core/test/utils/Deployers.sol";
// import {TestERC20} from "v4-core/src/test/TestERC20.sol";
// import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
// import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
// import {PoolManager} from "v4-core/src/PoolManager.sol";
// import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
// import {Hooks} from "v4-core/src/libraries/Hooks.sol";
// import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
// import {CurrencyLibrary, Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
// import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
// import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
// import {TickMath} from "v4-core/src/libraries/TickMath.sol";
// import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
// import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
// import {SlugVis} from "test/shared/SlugVis.sol";
// import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
// import {LiquidityAmounts} from "v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";

// import {Doppler, Position} from "../src/Doppler.sol";
// import {DopplerImplementation} from "test/shared/DopplerImplementation.sol";
// import {BaseTest} from "test/shared/BaseTest.sol";

// contract DopplerTest is BaseTest {
//     using PoolIdLibrary for PoolKey;
//     using StateLibrary for IPoolManager;

//     function setUp() public override {
//         super.setUp();
//     }

//     // =========================================================================
//     //                          Integration Tests
//     // =========================================================================

//     function testRevertsBeforeStartTimeAndAfterEndTime() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime() - 1); // 1 second before the start time

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             vm.expectRevert(
//                 abi.encodeWithSelector(
//                     Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(InvalidTime.selector)
//                 )
//             );
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             vm.warp(ghosts()[i].hook.getEndingTime() + 1); // 1 second after the end time

//             vm.expectRevert(
//                 abi.encodeWithSelector(
//                     Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(InvalidTime.selector)
//                 )
//             );
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );
//         }
//     }

//     function testDoesNotRebalanceTwiceInSameEpoch() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
//                 ghosts()[i].hook.state();

//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
//                 ghosts()[i].hook.state();

//             // Ensure that state hasn't updated since we're still in the same epoch
//             assertEq(lastEpoch, lastEpoch2);
//             assertEq(tickAccumulator, tickAccumulator2);
//             assertEq(totalTokensSoldLastEpoch, totalTokensSoldLastEpoch2);

//             // Ensure that we're tracking the amount of tokens sold
//             assertEq(totalTokensSold + 1 ether, totalTokensSold2);
//         }
//     }

//     function testUpdatesLastEpoch() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch,,,,) = ghosts()[i].hook.state();

//             assertEq(lastEpoch, 1);

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (lastEpoch,,,,) = ghosts()[i].hook.state();

//             assertEq(lastEpoch, 2);
//         }
//     }

//     function testUpdatesTotalTokensSoldLastEpoch() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) = ghosts()[i].hook.state();

//             assertEq(totalTokensSold, 2e18);
//             assertEq(totalTokensSoldLastEpoch, 1e18);
//         }
//     }

//     function testMaxDutchAuction() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
//                 ghosts()[i].hook.state();

//             assertEq(lastEpoch, 1);
//             // We sold 1e18 tokens just now
//             assertEq(totalTokensSold, 1e18);
//             // Previous epoch didn't exist so no tokens would have been sold at the time
//             assertEq(totalTokensSoldLastEpoch, 0);

//             // Swap tokens back into the pool, netSold == 0
//             swapRouter.swap(
//                 // Swap asset to numeraire
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(isToken0, -1 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch2,, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
//                 ghosts()[i].hook.state();

//             assertEq(lastEpoch2, 1);
//             // We unsold all the previously sold tokens
//             assertEq(totalTokensSold2, 0);
//             // This is unchanged because we're still referencing the epoch which didn't exist
//             assertEq(totalTokensSoldLastEpoch2, 0);

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

//             // We swap again just to trigger the rebalancing logic in the new epoch
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch3, int256 tickAccumulator3, uint256 totalTokensSold3,, uint256 totalTokensSoldLastEpoch3) =
//                 ghosts()[i].hook.state();

//             assertEq(lastEpoch3, 2);
//             // We sold some tokens just now
//             assertEq(totalTokensSold3, 1e18);
//             // The net sold amount in the previous epoch was 0
//             assertEq(totalTokensSoldLastEpoch3, 0);

//             // Assert that we reduced the accumulator by the max amount as intended
//             int256 maxTickDeltaPerEpoch = ghosts()[i].hook.getMaxTickDeltaPerEpoch();
//             assertEq(tickAccumulator3, tickAccumulator + maxTickDeltaPerEpoch);

//             // Get positions
//             Position memory lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
//             Position memory upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
//             Position memory priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

//             // Get global lower and upper ticks
//             (, int24 tickUpper) = ghosts()[i].hook.getTicksBasedOnState(tickAccumulator3, poolKey.tickSpacing);

//             // Get current tick
//             PoolId poolId = poolKey.toId();
//             (, int24 currentTick,,) = manager.getSlot0(poolId);

//             // Slugs must be inline and continuous
//             assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
//             assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
//             assertEq(priceDiscoverySlug.tickUpper, tickUpper);

//             // Lower slug should be unset with ticks at the current price
//             assertEq(lowerSlug.tickLower, lowerSlug.tickUpper);
//             assertEq(lowerSlug.liquidity, 0);
//             assertEq(lowerSlug.tickUpper, currentTick);

//             // Upper and price discovery slugs must be set
//             assertNotEq(upperSlug.liquidity, 0);
//             assertNotEq(priceDiscoverySlug.liquidity, 0);
//         }
//     }

//     function testRelativeDutchAuction() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             // Get the expected amount sold by next epoch
//             uint256 expectedAmountSold = ghosts()[i].hook.getExpectedAmountSold(
//                 ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()
//             );

//             // We sell half the expected amount
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(
//                     !isToken0, int256(expectedAmountSold / 2), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
//                 ),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
//                 ghosts()[i].hook.state();

//             assertEq(lastEpoch, 1);
//             // Confirm we sold half the expected amount
//             assertEq(totalTokensSold, expectedAmountSold / 2);
//             // Previous epoch didn't exist so no tokens would have been sold at the time
//             assertEq(totalTokensSoldLastEpoch, 0);

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

//             // We swap again just to trigger the rebalancing logic in the new epoch
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
//                 ghosts()[i].hook.state();

//             assertEq(lastEpoch2, 2);
//             // We sold some tokens just now
//             assertEq(totalTokensSold2, expectedAmountSold / 2 + 1e18);
//             // The net sold amount in the previous epoch half the expected amount
//             assertEq(totalTokensSoldLastEpoch2, expectedAmountSold / 2);

//             // Assert that we reduced the accumulator by half the max amount as intended
//             int256 maxTickDeltaPerEpoch = ghosts()[i].hook.getMaxTickDeltaPerEpoch();
//             assertEq(tickAccumulator2, tickAccumulator + maxTickDeltaPerEpoch / 2);

//             // Get positions
//             Position memory lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
//             Position memory upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
//             Position memory priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

//             // Get global lower and upper ticks
//             (, int24 tickUpper) = ghosts()[i].hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

//             // Get current tick
//             PoolId poolId = poolKey.toId();
//             (, int24 currentTick,,) = manager.getSlot0(poolId);

//             // Slugs must be inline and continuous
//             assertEq(lowerSlug.tickUpper, upperSlug.tickLower);
//             assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
//             assertEq(priceDiscoverySlug.tickUpper, tickUpper);

//             // Lower slug upper tick should be at the currentTick
//             assertEq(lowerSlug.tickUpper, currentTick);

//             // All slugs must be set
//             assertNotEq(lowerSlug.liquidity, 0);
//             assertNotEq(upperSlug.liquidity, 0);
//             assertNotEq(priceDiscoverySlug.liquidity, 0);
//         }
//     }

//     function testOversoldCase() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             // Get the expected amount sold by next epoch
//             uint256 expectedAmountSold = ghosts()[i].hook.getExpectedAmountSold(
//                 ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()
//             );

//             // We buy 1.5x the expectedAmountSold
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(
//                     !isToken0, int256(expectedAmountSold * 3 / 2), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
//                 ),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) =
//                 ghosts()[i].hook.state();

//             assertEq(lastEpoch, 1);
//             // Confirm we sold the 1.5x the expectedAmountSold
//             assertEq(totalTokensSold, expectedAmountSold * 3 / 2);
//             // Previous epoch references non-existent epoch
//             assertEq(totalTokensSoldLastEpoch, 0);

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

//             // Get current tick
//             PoolId poolId = poolKey.toId();
//             (, int24 currentTick,,) = manager.getSlot0(poolId);

//             // We swap again just to trigger the rebalancing logic in the new epoch
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2) =
//                 ghosts()[i].hook.state();

//             assertEq(lastEpoch2, 2);
//             // We sold some tokens just now
//             assertEq(totalTokensSold2, expectedAmountSold * 3 / 2 + 1e18);
//             // The amount sold by the previous epoch
//             assertEq(totalTokensSoldLastEpoch2, expectedAmountSold * 3 / 2);

//             assertEq(tickAccumulator2, tickAccumulator + int24(ghosts()[i].hook.getElapsedGamma()));

//             // Get positions
//             Position memory lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
//             Position memory upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));
//             Position memory priceDiscoverySlug = ghosts()[i].hook.getPositions(bytes32(uint256(3)));

//             // Get global lower and upper ticks
//             (int24 tickLower, int24 tickUpper) =
//                 ghosts()[i].hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

//             // Get current tick
//             (, currentTick,,) = manager.getSlot0(poolId);

//             // TODO: Depending on the hook used, it's possible to hit the lower slug oversold case or not
//             //       Currently we're hitting the oversold case. As such, the assertions should be agnostic
//             //       to either case and should only validate that the slugs are placed correctly.

//             // Lower slug upper tick must not be greater than the currentTick
//             assertLe(lowerSlug.tickUpper, currentTick);

//             // Upper and price discovery slugs must be inline and continuous
//             assertEq(upperSlug.tickUpper, priceDiscoverySlug.tickLower);
//             assertEq(priceDiscoverySlug.tickUpper, tickUpper);

//             // All slugs must be set
//             assertNotEq(lowerSlug.liquidity, 0);
//             assertNotEq(upperSlug.liquidity, 0);
//             assertNotEq(priceDiscoverySlug.liquidity, 0);
//         }
//     }

//     function testLowerSlug_SufficientProceeds() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             // We start at the third epoch to allow some dutch auctioning
//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 2);

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             // Compute the expected amount sold to see how many tokens will be supplied in the upper slug
//             // We should always have sufficient proceeds if we don't swap beyond the upper slug
//             uint256 expectedAmountSold = ghosts()[i].hook.getExpectedAmountSold(
//                 ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 3
//             );

//             // We sell half the expected amount to ensure that we don't surpass the upper slug
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(
//                     !isToken0, int256(expectedAmountSold / 2), !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
//                 ),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (uint40 lastEpoch,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch) = ghosts()[i].hook.state();

//             assertEq(lastEpoch, 3);
//             // Confirm we sold the correct amount
//             assertEq(totalTokensSold, expectedAmountSold / 2);
//             // Previous epoch references non-existent epoch
//             assertEq(totalTokensSoldLastEpoch, 0);

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 3); // Next epoch

//             // We swap again just to trigger the rebalancing logic in the new epoch
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             (, int256 tickAccumulator2,,,) = ghosts()[i].hook.state();

//             // Get the lower slug
//             Position memory lowerSlug = ghosts()[i].hook.getPositions(bytes32(uint256(1)));
//             Position memory upperSlug = ghosts()[i].hook.getPositions(bytes32(uint256(2)));

//             // Get global lower tick
//             (int24 tickLower,) = ghosts()[i].hook.getTicksBasedOnState(tickAccumulator2, poolKey.tickSpacing);

//             // Validate that the lower slug is spanning the full range
//             assertEq(tickLower, lowerSlug.tickLower);
//             assertEq(lowerSlug.tickUpper, upperSlug.tickLower);

//             // Validate that the lower slug has liquidity
//             assertGt(lowerSlug.liquidity, 0);
//         }
//     }

//     // testLowerSlug_SufficientLiquidity (fuzz?)

//     // testUpperSlug_UnderSold

//     // testUpperSlug_OverSold

//     function testCannotSwapBelowLowerSlug_AfterInitialization() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             vm.expectRevert(
//                 abi.encodeWithSelector(
//                     Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(SwapBelowRange.selector)
//                 )
//             );
//             // Attempt 0 amount swap below lower slug
//             swapRouter.swap(
//                 // Swap asset to numeraire
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(isToken0, 1, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );
//         }
//     }

//     function testCannotSwapBelowLowerSlug_AfterSoldAndUnsold() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());

//             PoolKey memory poolKey = ghosts()[i].key();
//             bool isToken0 = ghosts()[i].hook.getIsToken0();

//             // Sell some tokens
//             swapRouter.swap(
//                 // Swap numeraire to asset
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength()); // Next epoch

//             // Swap to trigger lower slug being created
//             // Unsell half of sold tokens
//             swapRouter.swap(
//                 // Swap asset to numeraire
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(isToken0, -0.5 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );

//             vm.expectRevert(
//                 abi.encodeWithSelector(
//                     Wrap__FailedHookCall.selector, ghosts()[i].hook, abi.encodeWithSelector(SwapBelowRange.selector)
//                 )
//             );
//             // Unsell beyond remaining tokens, moving price below lower slug
//             swapRouter.swap(
//                 // Swap asset to numeraire
//                 // If zeroForOne, we use max price limit (else vice versa)
//                 poolKey,
//                 IPoolManager.SwapParams(isToken0, -0.6 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
//                 PoolSwapTest.TestSettings(true, false),
//                 ""
//             );
//         }
//     }

//     // =========================================================================
//     //                         beforeSwap Unit Tests
//     // =========================================================================

//     function testBeforeSwap_RevertsIfNotPoolManager() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             PoolKey memory poolKey = ghosts()[i].key();

//             vm.expectRevert(SafeCallback.NotPoolManager.selector);
//             ghosts()[i].hook.beforeSwap(
//                 address(this),
//                 poolKey,
//                 IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
//                 ""
//             );
//         }
//     }

//     // =========================================================================
//     //                          afterSwap Unit Tests
//     // =========================================================================

//     function testAfterSwap_revertsIfNotPoolManager() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             PoolKey memory poolKey = ghosts()[i].key();

//             vm.expectRevert(SafeCallback.NotPoolManager.selector);
//             ghosts()[i].hook.afterSwap(
//                 address(this),
//                 poolKey,
//                 IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
//                 toBalanceDelta(0, 0),
//                 ""
//             );
//         }
//     }

//     // =========================================================================
//     //                      beforeAddLiquidity Unit Tests
//     // =========================================================================

//     function testBeforeAddLiquidity_RevertsIfNotPoolManager() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             PoolKey memory poolKey = ghosts()[i].key();

//             vm.expectRevert(SafeCallback.NotPoolManager.selector);
//             ghosts()[i].hook.beforeAddLiquidity(
//                 address(this),
//                 poolKey,
//                 IPoolManager.ModifyLiquidityParams({
//                     tickLower: -100_000,
//                     tickUpper: 100_000,
//                     liquidityDelta: 100e18,
//                     salt: bytes32(0)
//                 }),
//                 ""
//             );
//         }
//     }

//     function testBeforeAddLiquidity_ReturnsSelectorForHookCaller() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             PoolKey memory poolKey = ghosts()[i].key();

//             vm.prank(address(manager));
//             bytes4 selector = ghosts()[i].hook.beforeAddLiquidity(
//                 address(ghosts()[i].hook),
//                 poolKey,
//                 IPoolManager.ModifyLiquidityParams({
//                     tickLower: -100_000,
//                     tickUpper: 100_000,
//                     liquidityDelta: 100e18,
//                     salt: bytes32(0)
//                 }),
//                 ""
//             );

//             assertEq(selector, BaseHook.beforeAddLiquidity.selector);
//         }
//     }

//     function testBeforeAddLiquidity_RevertsForNonHookCaller() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             PoolKey memory poolKey = ghosts()[i].key();

//             vm.prank(address(manager));
//             vm.expectRevert(Unauthorized.selector);
//             ghosts()[i].hook.beforeAddLiquidity(
//                 address(0xBEEF),
//                 poolKey,
//                 IPoolManager.ModifyLiquidityParams({
//                     tickLower: -100_000,
//                     tickUpper: 100_000,
//                     liquidityDelta: 100e18,
//                     salt: bytes32(0)
//                 }),
//                 ""
//             );
//         }
//     }

//     // =========================================================================
//     //                   _getExpectedAmountSold Unit Tests
//     // =========================================================================

//     function testGetExpectedAmountSold_ReturnsExpectedAmountSold(uint64 timePercentage) public {
//         vm.assume(timePercentage <= 1e18);

//         for (uint256 i; i < ghosts().length; ++i) {
//             uint256 timeElapsed =
//                 (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime()) * timePercentage / 1e18;
//             uint256 timestamp = ghosts()[i].hook.getStartingTime() + timeElapsed;
//             vm.warp(timestamp);

//             uint256 expectedAmountSold = ghosts()[i].hook.getExpectedAmountSold(timestamp);

//             assertApproxEqAbs(
//                 timestamp,
//                 ghosts()[i].hook.getStartingTime()
//                     + (expectedAmountSold * 1e18 / ghosts()[i].hook.getNumTokensToSell())
//                         * (ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime()) / 1e18,
//                 1
//             );
//         }
//     }

//     // =========================================================================
//     //                  _getMaxTickDeltaPerEpoch Unit Tests
//     // =========================================================================

//     function testGetMaxTickDeltaPerEpoch_ReturnsExpectedAmount() public view {
//         for (uint256 i; i < ghosts().length; ++i) {
//             int256 maxTickDeltaPerEpoch = ghosts()[i].hook.getMaxTickDeltaPerEpoch();

//             assertApproxEqAbs(
//                 ghosts()[i].hook.getEndingTick(),
//                 (
//                     (
//                         maxTickDeltaPerEpoch
//                             * (
//                                 int256((ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getStartingTime()))
//                                     / int256(ghosts()[i].hook.getEpochLength())
//                             )
//                     ) / 1e18 + ghosts()[i].hook.getStartingTick()
//                 ),
//                 1
//             );
//         }
//     }

//     // =========================================================================
//     //                   _getElapsedGamma Unit Tests
//     // =========================================================================

//     function testGetElapsedGamma_ReturnsExpectedAmountSold() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             uint256 timestamp = ghosts()[i].hook.getStartingTime();
//             vm.warp(timestamp);

//             assertEq(
//                 ghosts()[i].hook.getElapsedGamma(),
//                 int256(ghosts()[i].hook.getNormalizedTimeElapsed(timestamp)) * int256(ghosts()[i].hook.getGamma())
//                     / 1e18
//             );

//             timestamp = ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength();
//             vm.warp(timestamp);

//             assertEq(
//                 ghosts()[i].hook.getElapsedGamma(),
//                 int256(ghosts()[i].hook.getNormalizedTimeElapsed(timestamp)) * int256(ghosts()[i].hook.getGamma())
//                     / 1e18
//             );

//             timestamp = ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 2;
//             vm.warp(timestamp);

//             assertEq(
//                 ghosts()[i].hook.getElapsedGamma(),
//                 int256(ghosts()[i].hook.getNormalizedTimeElapsed(timestamp)) * int256(ghosts()[i].hook.getGamma())
//                     / 1e18
//             );

//             timestamp = ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getEpochLength() * 2;
//             vm.warp(timestamp);

//             assertEq(
//                 ghosts()[i].hook.getElapsedGamma(),
//                 int256(ghosts()[i].hook.getNormalizedTimeElapsed(timestamp)) * int256(ghosts()[i].hook.getGamma())
//                     / 1e18
//             );

//             timestamp = ghosts()[i].hook.getEndingTime() - ghosts()[i].hook.getEpochLength();
//             vm.warp(timestamp);

//             assertEq(
//                 ghosts()[i].hook.getElapsedGamma(),
//                 int256(ghosts()[i].hook.getNormalizedTimeElapsed(timestamp)) * int256(ghosts()[i].hook.getGamma())
//                     / 1e18
//             );

//             timestamp = ghosts()[i].hook.getEndingTime();
//             vm.warp(timestamp);

//             assertEq(
//                 ghosts()[i].hook.getElapsedGamma(),
//                 int256(ghosts()[i].hook.getNormalizedTimeElapsed(timestamp)) * int256(ghosts()[i].hook.getGamma())
//                     / 1e18
//             );
//         }
//     }

//     // =========================================================================
//     //                   _getTicksBasedOnState Unit Tests
//     // =========================================================================

//     // TODO: int16 accumulator might over/underflow with certain states
//     //       Consider whether we need to protect against this in the contract or whether it's not a concern
//     function testGetTicksBasedOnState_ReturnsExpectedAmountSold(int16 accumulator) public view {
//         for (uint256 i; i < ghosts().length; ++i) {
//             PoolKey memory poolKey = ghosts()[i].key();

//             (int24 tickLower, int24 tickUpper) = ghosts()[i].hook.getTicksBasedOnState(accumulator, poolKey.tickSpacing);
//             int24 gamma = ghosts()[i].hook.getGamma();

//             if (ghosts()[i].hook.getStartingTick() > ghosts()[i].hook.getEndingTick()) {
//                 assertEq(int256(gamma), tickUpper - tickLower);
//             } else {
//                 assertEq(int256(gamma), tickLower - tickUpper);
//             }
//         }
//     }

//     // =========================================================================
//     //                     _getCurrentEpoch Unit Tests
//     // =========================================================================

//     function testGetCurrentEpoch_ReturnsCorrectEpoch() public {
//         for (uint256 i; i < ghosts().length; ++i) {
//             vm.warp(ghosts()[i].hook.getStartingTime());
//             uint256 currentEpoch = ghosts()[i].hook.getCurrentEpoch();

//             assertEq(currentEpoch, 1);

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength());
//             currentEpoch = ghosts()[i].hook.getCurrentEpoch();

//             assertEq(currentEpoch, 2);

//             vm.warp(ghosts()[i].hook.getStartingTime() + ghosts()[i].hook.getEpochLength() * 2);
//             currentEpoch = ghosts()[i].hook.getCurrentEpoch();

//             assertEq(currentEpoch, 3);
//         }
//     }

//     // =========================================================================
//     //                     _computeLiquidity Unit Tests
//     // =========================================================================

//     function testComputeLiquidity_IsSymmetric(bool forToken0, uint160 lowerPrice, uint160 upperPrice, uint256 amount)
//         public
//         view
//     {
//         for (uint256 i; i < ghosts().length; ++i) {}
//     }
// }

// error Unauthorized();
// error InvalidTime();
// error Wrap__FailedHookCall(address, bytes);
// error SwapBelowRange();
