// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "@v4-core/PoolManager.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Pool } from "@v4-core/libraries/Pool.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { Pool } from "@v4-core/libraries/Pool.sol";
import { CustomRouter } from "test/shared/CustomRouter.sol";
import { DopplerImplementation } from "test/shared/DopplerImplementation.sol";
import { MAX_SWAP_FEE } from "src/Doppler.sol";
import { AddressSet, LibAddressSet } from "test/invariant/AddressSet.sol";
import { CustomRevertDecoder } from "test/utils/CustomRevertDecoder.sol";
import { InvalidSwapAfterMaturityInsufficientProceeds, SwapBelowRange, MaximumProceedsReached } from "src/Doppler.sol";

uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

uint256 constant TOTAL_WEIGHTS = 100;

contract DopplerHandler is Test {
    using LibAddressSet for AddressSet;
    using StateLibrary for IPoolManager;

    PoolKey public poolKey;
    DopplerImplementation public hook;
    CustomRouter public router;
    PoolSwapTest public swapRouter;
    TestERC20 public token0;
    TestERC20 public token1;
    TestERC20 public numeraire;
    TestERC20 public asset;
    bool public isToken0;
    bool public isUsingEth;

    // Ghost variables are used to mimic the state of the hook contract.
    uint256 public ghost_reserve0;
    uint256 public ghost_reserve1;
    uint256 public ghost_totalTokensSold;
    uint256 public ghost_totalProceeds;
    uint256 public ghost_numTokensSold;

    uint256 public ghost_token0Fees;
    uint256 public ghost_token1Fees;

    bool public ghost_hasRebalanced;

    uint256 public ghost_currentEpoch;

    AddressSet internal actors;
    address internal currentActor;

    mapping(address actor => uint256 balance) public assetBalanceOf;

    mapping(bytes4 => uint256) public selectorWeights;

    modifier createActor() {
        currentActor = msg.sender;
        actors.add(msg.sender);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useActor(
        uint256 actorIndexSeed
    ) {
        currentActor = actors.rand(actorIndexSeed);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        PoolKey memory poolKey_,
        DopplerImplementation hook_,
        CustomRouter router_,
        PoolSwapTest swapRouter_,
        bool isToken0_,
        bool isUsingEth_
    ) {
        poolKey = poolKey_;
        hook = hook_;
        router = router_;
        swapRouter = swapRouter_;
        isToken0 = isToken0_;
        isUsingEth = isUsingEth_;

        if (Currency.unwrap(poolKey.currency0) != address(0)) {
            token0 = TestERC20(Currency.unwrap(poolKey.currency0));
            ghost_reserve0 = token0.balanceOf(address(hook));
        } else {
            ghost_reserve0 = address(hook).balance;
        }

        token1 = TestERC20(Currency.unwrap(poolKey.currency1));
        // ghost_reserve1 = token1.balanceOf(address(hook));

        if (isToken0) {
            asset = token0;
            numeraire = token1;
        } else {
            asset = token1;
            numeraire = token0;
        }

        ghost_currentEpoch = hook.getCurrentEpoch();
    }

    /// @notice Buys an amount of asset tokens using an exact amount of numeraire tokens
    function buyExactAmountIn(
        uint256 amount
    ) public createActor {
        amount = amount % 10 ether + 0.001 ether;

        if (ghost_totalTokensSold > 0 && block.timestamp > hook.startingTime()) {
            ghost_hasRebalanced = true;
        }

        if (isUsingEth) {
            deal(currentActor, amount);
        } else {
            numeraire.mint(currentActor, amount);
            numeraire.approve(address(swapRouter), amount);
        }

        try swapRouter.swap{ value: isUsingEth ? amount : 0 }(
            poolKey,
            IPoolManager.SwapParams(!isToken0, -int256(amount), isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (BalanceDelta delta) {
            uint256 delta0 = uint256(int256(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()));
            uint256 delta1 = uint256(int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));

            uint256 bought = isToken0 ? delta0 : delta1;
            uint256 spent = isToken0 ? delta1 : delta0;
            ghost_numTokensSold += bought;

            assetBalanceOf[currentActor] += bought;
            ghost_totalTokensSold += bought;

            uint256 proceedsLessFee = FullMath.mulDiv(uint128(spent), MAX_SWAP_FEE - hook.initialLpFee(), MAX_SWAP_FEE);
            ghost_totalProceeds += proceedsLessFee;

            if (isToken0) {
                ghost_token1Fees += spent - proceedsLessFee;
            } else {
                ghost_token0Fees += spent - proceedsLessFee;
            }
        } catch (bytes memory err) {
            bytes4 selector;

            assembly {
                selector := mload(add(err, 0x20))
            }

            if (selector == CustomRevert.WrappedError.selector) {
                (,,, bytes4 revertReasonSelector,,) = CustomRevertDecoder.decode(err);

                if (revertReasonSelector == InvalidSwapAfterMaturityInsufficientProceeds.selector) {
                    revert("invalid swap after maturity");
                } else if (revertReasonSelector == Pool.TicksMisordered.selector) {
                    revert("ticks misordered");
                } else if (revertReasonSelector == TickMath.InvalidSqrtPrice.selector) {
                    revert("invalid sqrt price");
                } else if (revertReasonSelector == MaximumProceedsReached.selector) {
                    return;
                } else {
                    revert("Unimplemented error");
                }
            } else if (selector == InvalidSwapAfterMaturityInsufficientProceeds.selector) {
                revert("invalid swap after maturity");
            } else if (selector == Pool.PriceLimitAlreadyExceeded.selector) {
                // revert("price limit already exceeded");
            } else {
                revert("Unknown error");
            }
        }
    }

    function buyExactAmountOut(
        uint256 assetsToBuy
    ) public createActor {
        vm.assume(assetsToBuy > 0 && assetsToBuy <= hook.numTokensToSell());
        assetsToBuy = 1 ether;
        uint256 amountInRequired = router.computeBuyExactOut(assetsToBuy);

        if (isUsingEth) {
            deal(currentActor, amountInRequired);
        } else {
            numeraire.mint(currentActor, amountInRequired);
            numeraire.approve(address(router), amountInRequired);
        }

        uint256 spent = router.buyExactOut{ value: isUsingEth ? amountInRequired : 0 }(assetsToBuy);
        assetBalanceOf[currentActor] += assetsToBuy;
        ghost_totalTokensSold += assetsToBuy;

        uint256 proceedsLessFee = FullMath.mulDiv(uint128(spent), MAX_SWAP_FEE - hook.initialLpFee(), MAX_SWAP_FEE);
        ghost_totalProceeds += proceedsLessFee;

        /*
        if (isToken0) {
            ghost_reserve0 -= assetsToBuy;
            ghost_reserve1 += proceedsLessFee;
        } else {
            ghost_reserve1 -= assetsToBuy;
            ghost_reserve0 += proceedsLessFee;
        }
        */

        if (block.timestamp > hook.startingTime()) {
            ghost_hasRebalanced = true;
        }
    }

    function sellExactIn(
        uint256 seed
    ) public useActor(uint256(uint160(msg.sender))) {
        // If the currentActor is address(0), it means no one has bought any assets yet.
        // vm.assume(currentActor != address(0) && assetBalanceOf[currentActor] > 0);
        if (currentActor == address(0) || assetBalanceOf[currentActor] == 0) return;

        uint256 assetsToSell = seed % assetBalanceOf[currentActor] + 1;
        assertLe(assetsToSell, assetBalanceOf[currentActor]);

        TestERC20(asset).approve(address(swapRouter), assetsToSell);

        try swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(isToken0, -int256(assetsToSell), isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) returns (BalanceDelta delta) {
            uint256 delta0 = uint256(int256(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()));
            uint256 delta1 = uint256(int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));

            uint256 sold = isToken0 ? delta0 : delta1;
            uint256 received = isToken0 ? delta1 : delta0;
            uint256 soldLessFee = FullMath.mulDiv(uint128(sold), MAX_SWAP_FEE - hook.initialLpFee(), MAX_SWAP_FEE);

            ghost_numTokensSold -= sold;
            ghost_totalTokensSold -= soldLessFee;
            ghost_totalProceeds -= received;
            assetBalanceOf[currentActor] -= sold;

            if (isToken0) {
                ghost_token0Fees += sold - soldLessFee;
            } else {
                ghost_token1Fees += sold - soldLessFee;
            }
        } catch (bytes memory err) {
            bytes4 selector;

            assembly {
                selector := mload(add(err, 0x20))
            }

            if (selector == CustomRevert.WrappedError.selector) {
                (,,, bytes4 revertReasonSelector,,) = CustomRevertDecoder.decode(err);

                if (revertReasonSelector == SwapBelowRange.selector) {
                    revert("swap below range");
                } else if (revertReasonSelector == TickMath.InvalidSqrtPrice.selector) {
                    revert("invalid sqrt price");
                } else if (revertReasonSelector == MaximumProceedsReached.selector) {
                    return;
                } else if (revertReasonSelector == bytes4(0)) {
                    revert("Wrapped error without revert reason");
                } else {
                    revert("Unimplemented wrapped error");
                }
            } else {
                revert("Unimplemented error");
            }
        }

        /*
        if (isToken0) {
            ghost_reserve0 += assetsToSell;
            ghost_reserve1 -= received;
        } else {
            ghost_reserve1 += assetsToSell;
            ghost_reserve0 -= received;
        }
        */

        if (block.timestamp > hook.startingTime()) {
            ghost_hasRebalanced = true;
        }
    }

    function sellExactOut(
        uint256 seed
    ) public useActor(uint256(uint160(msg.sender))) {
        // If the currentActor is address(0), it means no one has bought any assets yet.
        if (currentActor == address(0) || assetBalanceOf[currentActor] == 0) return;

        // We compute the maximum amount we can receive from our current balance.
        uint256 maxAmountToReceive = router.computeSellExactOut(assetBalanceOf[currentActor]);

        // Then we compute a random amount from that maximum.
        uint256 amountToReceive = seed % maxAmountToReceive + 1;

        TestERC20(asset).approve(address(router), router.computeSellExactOut(amountToReceive));
        uint256 sold = router.sellExactOut(amountToReceive);

        assetBalanceOf[currentActor] -= sold;
        ghost_totalTokensSold += sold;
        ghost_totalProceeds -= amountToReceive;

        if (isToken0) {
            ghost_reserve0 += sold;
            ghost_reserve1 -= amountToReceive;
        } else {
            ghost_reserve0 -= amountToReceive;
            ghost_reserve1 += sold;
        }

        if (block.timestamp > hook.startingTime()) {
            ghost_hasRebalanced = true;
        }
    }

    /// @dev Jumps to the next epoch
    function goNextEpoch(
        uint256 seed
    ) public {
        uint256 rand = seed % 100;
        vm.assume(rand > 80);
        vm.warp(block.timestamp + hook.epochLength());
        ghost_currentEpoch += 1;
    }
}
