pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MAX_SWAP_FEE} from "src/Doppler.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {ProtocolFeeLibrary} from "v4-periphery/lib/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {console} from "forge-std/console.sol";
import {
    InvalidTime,
    SwapBelowRange,
    InvalidSwapAfterMaturityInsufficientProceeds,
    InvalidSwapAfterMaturitySufficientProceeds
} from "src/Doppler.sol";
import {BaseTest} from "test/shared/BaseTest.sol";
import {Position} from "../../src/Doppler.sol";

contract SwapTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for *;

    function test_swap_RevertsBeforeStartTime() public {
        vm.warp(hook.getStartingTime() - 1); // 1 second before the start time

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector, hook, abi.encodeWithSelector(InvalidTime.selector)
            )
        );
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }

    function test_swap_RevertsAfterEndTimeInsufficientProceedsAssetBuy() public {
        vm.warp(hook.getStartingTime()); // 1 second after the end time

        int256 targetProceeds = int256(hook.getTargetProceeds());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, targetProceeds / 2, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
        vm.warp(hook.getEndingTime() + 1); // 1 second after the end time

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                hook,
                abi.encodeWithSelector(InvalidSwapAfterMaturityInsufficientProceeds.selector)
            )
        );
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }

    function test_swap_RevertsAfterEndTimeSufficientProceeds() public {
        vm.warp(hook.getStartingTime()); // 1 second after the end time

        int256 targetProceeds = int256(hook.getTargetProceeds());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, targetProceeds, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.warp(hook.getEndingTime() + 1); // 1 second after the end time

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                hook,
                abi.encodeWithSelector(InvalidSwapAfterMaturitySufficientProceeds.selector)
            )
        );
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }

    function test_swap_DoesNotRebalanceTwiceInSameEpoch() public {
        vm.warp(hook.getStartingTime());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch, int256 tickAccumulator, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) =
            hook.state();

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch2, int256 tickAccumulator2, uint256 totalTokensSold2,, uint256 totalTokensSoldLastEpoch2,) =
            hook.state();

        // Ensure that state hasn't updated since we're still in the same epoch
        assertEq(lastEpoch, lastEpoch2);
        assertEq(tickAccumulator, tickAccumulator2);
        assertEq(totalTokensSoldLastEpoch, totalTokensSoldLastEpoch2);

        // Ensure that we're tracking the amount of tokens sold
        assertEq(totalTokensSold + 1 ether, totalTokensSold2);
    }

    function test_swap_UpdatesLastEpoch() public {
        vm.warp(hook.getStartingTime());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (uint40 lastEpoch,,,,,) = hook.state();

        assertEq(lastEpoch, 1);

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (lastEpoch,,,,,) = hook.state();

        assertEq(lastEpoch, 2);
    }

    function test_swap_UpdatesTotalTokensSoldLastEpoch() public {
        vm.warp(hook.getStartingTime());

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (,, uint256 totalTokensSold,, uint256 totalTokensSoldLastEpoch,) = hook.state();

        assertEq(totalTokensSold, 2e18);
        assertEq(totalTokensSoldLastEpoch, 1e18);
    }

    function test_swap_UpdatesTotalProceedsAndTotalTokensSoldLessFee() public {
        vm.warp(hook.getStartingTime());
        (,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        uint24 swapFee = uint16(protocolFee).calculateSwapFee(lpFee);

        int256 amountIn = 1 ether;

        uint256 amountInLessFee = FullMath.mulDiv(uint256(amountIn), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams(!isToken0, -amountIn, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (,, uint256 totalTokensSold, uint256 totalProceeds,,) = hook.state();

        assertEq(totalProceeds, amountInLessFee);

        amountInLessFee = FullMath.mulDiv(uint256(totalTokensSold), MAX_SWAP_FEE - swapFee, MAX_SWAP_FEE);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams(isToken0, -int256(totalTokensSold), isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        (,, uint256 totalTokensSold2,,,) = hook.state();

        assertEq(totalTokensSold2, totalTokensSold - amountInLessFee);
    }

    function test_swap_CannotSwapBelowLowerSlug_AfterInitialization() public {
        vm.warp(hook.getStartingTime());

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector, hook, abi.encodeWithSelector(SwapBelowRange.selector)
            )
        );
        // Attempt 0 amount swap below lower slug
        swapRouter.swap(
            // Swap asset to numeraire
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(isToken0, 1, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }

    function test_swap_CannotSwapBelowLowerSlug_AfterSoldAndUnsold() public {
        vm.warp(hook.getStartingTime());

        // Sell some tokens
        swapRouter.swap(
            // Swap numeraire to asset
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(!isToken0, 1 ether, !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.warp(hook.getStartingTime() + hook.getEpochLength()); // Next epoch

        // Swap to trigger lower slug being created
        // Unsell half of sold tokens
        swapRouter.swap(
            // Swap asset to numeraire
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(isToken0, -0.5 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector, hook, abi.encodeWithSelector(SwapBelowRange.selector)
            )
        );
        // Unsell beyond remaining tokens, moving price below lower slug
        swapRouter.swap(
            // Swap asset to numeraire
            // If zeroForOne, we use max price limit (else vice versa)
            key,
            IPoolManager.SwapParams(isToken0, -0.6 ether, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
    }
}
