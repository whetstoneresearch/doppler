pragma solidity 0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import {BaseTest, TestERC20} from "test/shared/BaseTest.sol";

/// @dev forge test -vvv --mc DopplerBeforeSwapTest --via-ir
/// TODO: I duplicated this from the test file just to test this out for now.
contract DopplerBeforeSwapTest is BaseTest {
    // =========================================================================
    //                         beforeSwap Unit Tests
    // =========================================================================

    function testBeforeSwap_RevertsIfNotPoolManager() public {
        vm.expectRevert(SafeCallback.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
            ""
        );
    }

    // TODO: get this test to trigger the case in `_rebalance` where `requiredProceeds > totalProceeds_`.
    // TODO: Doppler.sol#L122 is using `amount1` instead of `amount0`.
    function testBeforeSwap_RebalanceToken1() public {
        // Deploy a new Doppler with `isToken0 = false`

        TestERC20 asset_ = new TestERC20(2 ** 128);
        TestERC20 numeraire_ = new TestERC20(2 ** 128);

        // Reorg the asset and the numeraire so the asset will be the token1
        (asset_, numeraire_) = address(asset_) > address(numeraire_) ? (asset_, numeraire_) : (numeraire_, asset_);

        _deploy(
            asset_,
            numeraire_,
            DopplerConfig({
                numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
                startingTime: DEFAULT_STARTING_TIME,
                endingTime: DEFAULT_ENDING_TIME,
                gamma: DEFAULT_GAMMA,
                epochLength: 1 days,
                fee: DEFAULT_FEE,
                tickSpacing: DEFAULT_TICK_SPACING
            })
        );

        vm.warp(hook.getStartingTime());

        vm.prank(address(manager));
        (bytes4 selector0, int128 hookDelta) = hook.afterSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1e2, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
            toBalanceDelta(-1e2, 10e18),
            ""
        );

        assertEq(selector0, BaseHook.afterSwap.selector);
        assertEq(hookDelta, 0);

        vm.warp(hook.getStartingTime() + hook.getEpochLength());

        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 100e18, sqrtPriceLimitX96: SQRT_RATIO_2_1}),
            ""
        );

        assertEq(selector, BaseHook.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }
}
