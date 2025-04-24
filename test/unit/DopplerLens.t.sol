// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { stdMath } from "forge-std/StdMath.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ProtocolFeeLibrary } from "@v4-core/libraries/ProtocolFeeLibrary.sol";
import { BaseTest } from "test/shared/BaseTest.sol";
import { SlugVis } from "test/shared/SlugVis.sol";
import { SlugVis } from "test/shared/SlugVis.sol";
import { Position, MAX_SWAP_FEE } from "src/Doppler.sol";
import { StateView } from "@uniswap/v4-periphery/src/lens/StateView.sol";
import { DopplerLensQuoter } from "../../src/lens/DopplerLens.sol";
import { IV4Quoter } from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

contract RebalanceTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using ProtocolFeeLibrary for *;
    using stdMath for *;

    DopplerLensQuoter public lensQuoter;

    function deployLensQuoter() internal {
        StateView stateView = new StateView(manager);
        lensQuoter = new DopplerLensQuoter(manager, stateView);
    }

    modifier _deployLensQuoter() {
        deployLensQuoter();
        _;
    }

    function test_lens_fetches_consistent_ticks() public _deployLensQuoter {
        vm.warp(hook.getStartingTime());

        // Get istoken0
        bool isToken0 = hook.isToken0();

        int24 tick0 = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        vm.warp(hook.getStartingTime() + hook.getEpochLength());

        int24 tick1 = lensQuoter.quoteDopplerLensData(
            IV4Quoter.QuoteExactSingleParams({ poolKey: key, zeroForOne: !isToken0, exactAmount: 1, hookData: "" })
        );

        assertLt(tick1, tick0, "Tick should be less than the previous tick");
    }
}
