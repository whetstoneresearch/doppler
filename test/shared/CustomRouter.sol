// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/PoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IV4Quoter, V4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { Test } from "forge-std/Test.sol";

uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

/// @notice Just a custom router contract for testing purposes, I wanted to have
/// a way to reuse the same functions in the BaseTest contract and the DopplerHandler.
contract CustomRouter is Test {
    using BalanceDeltaLibrary for BalanceDelta;

    PoolSwapTest public swapRouter;
    V4Quoter public quoter;
    PoolKey public key;
    bool public isToken0;
    bool public isUsingEth;
    address public numeraire;
    address public asset;

    constructor(PoolSwapTest swapRouter_, V4Quoter quoter_, PoolKey memory key_, bool isToken0_, bool isUsingEth_) {
        swapRouter = swapRouter_;
        quoter = quoter_;
        key = key_;
        isToken0 = isToken0_;
        isUsingEth = isUsingEth_;

        asset = isToken0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        numeraire = isToken0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
    }

    function computeBuyExactOut(uint256 amountOut) public returns (uint256) {
        (uint256 amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: !isToken0, exactAmount: uint128(amountOut), hookData: ""
            })
        );

        return amountIn;
    }

    function computeSellExactOut(uint256 amountOut) public returns (uint256) {
        (uint256 amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: isToken0, exactAmount: uint128(amountOut), hookData: ""
            })
        );

        return amountIn;
    }

    /// @notice Buys asset tokens using an exact amount of numeraire tokens.
    /// @return bought Amount of asset tokens bought.
    function buyExactIn(uint256 amount) public payable returns (uint256 bought) {
        (bought,) = buy(-int256(amount));
    }

    /// @notice Buys an exact amount of asset tokens using numeraire tokens.
    function buyExactOut(uint256 amount) public payable returns (uint256 spent) {
        (, spent) = buy(int256(amount));
    }

    /// @notice Sells an exact amount of asset tokens for numeraire tokens.
    /// @return received Amount of numeraire tokens received.
    function sellExactIn(uint256 amount) public returns (uint256 received) {
        (, received) = sell(-int256(amount));
    }

    /// @notice Sells asset tokens for an exact amount of numeraire tokens.
    /// @return sold Amount of asset tokens sold.
    function sellExactOut(uint256 amount) public returns (uint256 sold) {
        (sold,) = sell(int256(amount));
    }

    /// @dev Buys a given amount of asset tokens.
    /// @param amount A negative value specificies the amount of numeraire tokens to spend,
    /// a positive value specifies the amount of asset tokens to buy.
    /// @return Amount of asset tokens bought.
    /// @return Amount of numeraire tokens used.
    function mintAndBuy(int256 amount) public returns (uint256, uint256) {
        // Negative means exactIn, positive means exactOut.
        uint256 mintAmount = amount < 0 ? uint256(-amount) : computeBuyExactOut(uint256(amount));

        // TODO: Not sure if minting should be done in here, it might be better to mint in the tests.
        if (isUsingEth) {
            deal(address(this), uint256(mintAmount));
        } else {
            TestERC20(numeraire).mint(address(this), uint256(mintAmount));
            TestERC20(numeraire).approve(address(swapRouter), uint256(mintAmount));
        }

        BalanceDelta delta = swapRouter.swap{ value: isUsingEth ? mintAmount : 0 }(
            key,
            IPoolManager.SwapParams(!isToken0, amount, isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        uint256 delta0 = uint256(int256(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()));
        uint256 delta1 = uint256(int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));

        uint256 bought = isToken0 ? delta0 : delta1;
        uint256 spent = isToken0 ? delta1 : delta0;

        TestERC20(asset).transfer(msg.sender, bought);

        return (bought, spent);
    }

    /// @dev Buys a given amount of asset tokens.
    /// @param amount A negative value specificies the amount of numeraire tokens to spend,
    /// a positive value specifies the amount of asset tokens to buy.
    /// @return Amount of asset tokens bought.
    /// @return Amount of numeraire tokens used.
    function buy(int256 amount) public payable returns (uint256, uint256) {
        // Negative means exactIn, positive means exactOut.
        uint256 transferAmount = amount < 0 ? uint256(-amount) : computeBuyExactOut(uint256(amount));

        if (isUsingEth) {
            require(msg.value == transferAmount, "Incorrect amount of ETH sent");
        } else {
            TestERC20(numeraire).transferFrom(msg.sender, address(this), transferAmount);
            TestERC20(numeraire).approve(address(swapRouter), transferAmount);
        }

        BalanceDelta delta = swapRouter.swap{ value: isUsingEth ? transferAmount : 0 }(
            key,
            IPoolManager.SwapParams(!isToken0, amount, isToken0 ? MAX_PRICE_LIMIT : MIN_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        uint256 delta0 = uint256(int256(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()));
        uint256 delta1 = uint256(int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));

        uint256 bought = isToken0 ? delta0 : delta1;
        uint256 spent = isToken0 ? delta1 : delta0;

        TestERC20(asset).transfer(msg.sender, bought);

        return (bought, spent);
    }

    /// @dev Sells a given amount of asset tokens.
    /// @param amount A negative value specificies the amount of asset tokens to sell, a positive value
    /// specifies the amount of numeraire tokens to receive.
    /// @return Amount of asset tokens sold.
    /// @return Amount of numeraire tokens received.
    function sell(int256 amount) public returns (uint256, uint256) {
        uint256 approveAmount = amount < 0 ? uint256(-amount) : computeSellExactOut(uint256(amount));
        TestERC20(asset).transferFrom(msg.sender, address(this), uint256(approveAmount));
        TestERC20(asset).approve(address(swapRouter), uint256(approveAmount));

        BalanceDelta delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams(isToken0, amount, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        uint256 delta0 = uint256(int256(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()));
        uint256 delta1 = uint256(int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));

        uint256 sold = isToken0 ? delta0 : delta1;
        uint256 received = isToken0 ? delta1 : delta0;

        if (isUsingEth) {
            payable(address(msg.sender)).transfer(received);
        } else {
            TestERC20(numeraire).transfer(msg.sender, received);
        }

        return (sold, received);
    }
}
