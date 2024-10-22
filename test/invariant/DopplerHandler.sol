// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {AddressSet, LibAddressSet} from "./AddressSet.sol";
import {DopplerImplementation} from "test/shared/DopplerImplementation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Quoter, IQuoter} from "v4-periphery/src/lens/Quoter.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

contract DopplerHandler is Test {
    using LibAddressSet for AddressSet;

    PoolKey public poolKey;
    DopplerImplementation public hook;
    PoolSwapTest public swapRouter;
    Quoter public quoter;
    TestERC20 public token0;
    TestERC20 public token1;
    TestERC20 public numeraire;
    TestERC20 public asset;
    bool public isToken0;
    bool public isUsingEth;

    uint256 public ghost_reserve0;
    uint256 public ghost_reserve1;

    mapping(bytes4 => uint256) public calls;
    uint256 public totalCalls;

    AddressSet internal actors;
    address internal currentActor;

    modifier createActor() {
        currentActor = msg.sender;
        actors.add(msg.sender);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors.rand(actorIndexSeed);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier countCall(bytes4 key) {
        calls[key]++;
        totalCalls++;
        _;
    }

    constructor(
        PoolKey memory poolKey_,
        DopplerImplementation hook_,
        PoolSwapTest swapRouter_,
        Quoter quoter_,
        bool isToken0_,
        bool isUsingEth_
    ) {
        poolKey = poolKey_;
        hook = hook_;
        swapRouter = swapRouter_;
        quoter = quoter_;
        isToken0 = isToken0_;
        isUsingEth = isUsingEth_;

        token0 = TestERC20(Currency.unwrap(poolKey.currency0));
        token1 = TestERC20(Currency.unwrap(poolKey.currency1));

        if (isToken0) {
            numeraire = token0;
            asset = token1;
        } else {
            numeraire = token1;
            asset = token0;
        }

        ghost_reserve0 = token0.balanceOf(address(hook));
        ghost_reserve1 = token1.balanceOf(address(hook));
    }

    function buyExactAmount(uint256 amount) public createActor countCall(this.buyExactAmount.selector) {}

    function computeBuyExactOut(uint256 amountOut) public returns (uint256) {
        (int128[] memory deltaAmounts,,) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: !isToken0,
                exactAmount: uint128(amountOut),
                sqrtPriceLimitX96: !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
                hookData: ""
            })
        );

        return uint256(uint128(deltaAmounts[0]));
    }

    function computeSellExactOut(uint256 amountOut) public returns (uint256) {
        (int128[] memory deltaAmounts,,) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: isToken0,
                exactAmount: uint128(amountOut),
                sqrtPriceLimitX96: isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
                hookData: ""
            })
        );

        return uint256(uint128(deltaAmounts[0]));
    }

    function buyExactIn(uint256 amount) public {
        buy(-int256(amount));
    }

    function buyExactOut(uint256 amount) public {
        buy(int256(amount));
    }

    function sellExactIn(uint256 amount) public {
        sell(-int256(amount));
    }

    function sellExactOut(uint256 amount) public {
        sell(int256(amount));
    }

    /// @dev Buys a given amount of asset tokens.
    /// @param amount A negative value specificies the amount of numeraire tokens to spend,
    /// a positive value specifies the amount of asset tokens to buy.
    function buy(int256 amount) public {
        // Negative means exactIn, positive means exactOut.
        uint256 mintAmount = amount < 0 ? uint256(-amount) : computeBuyExactOut(uint256(amount));

        if (isUsingEth) {
            deal(address(this), uint256(mintAmount));
        } else {
            TestERC20(numeraire).mint(address(this), uint256(mintAmount));
            TestERC20(numeraire).approve(address(swapRouter), uint256(mintAmount));
        }

        swapRouter.swap{value: isUsingEth ? mintAmount : 0}(
            poolKey,
            IPoolManager.SwapParams(!isToken0, amount, isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// @dev Sells a given amount of asset tokens.
    /// @param amount A negative value specificies the amount of asset tokens to sell, a positive value
    /// specifies the amount of numeraire tokens to receive.
    function sell(int256 amount) public {
        uint256 approveAmount = amount < 0 ? uint256(-amount) : computeSellExactOut(uint256(amount));
        TestERC20(asset).approve(address(swapRouter), uint256(approveAmount));

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(isToken0, amount, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}
