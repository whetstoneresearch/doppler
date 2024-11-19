/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "v4-core/src/test/TestERC20.sol";
import { PoolKey } from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import { IPoolManager } from "v4-core/src/PoolManager.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";
import { Quoter, IQuoter } from "v4-periphery/src/lens/Quoter.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { Doppler } from "../../src/Doppler.sol";

uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

/// @notice Just a custom router contract for testing purposes, I wanted to have
/// a way to reuse the same functions in the BaseTest contract and the DopplerHandler.
contract CustomRouter2 {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    PoolSwapTest public swapRouter;
    Quoter public quoter;

    constructor(PoolSwapTest swapRouter_, Quoter quoter_) {
        swapRouter = swapRouter_;
        quoter = quoter_;
    }

    function _getHookData(
        PoolKey calldata key
    ) internal view returns (bool isUsingEth, bool isToken0, address asset, address numeraire) {
        isToken0 = Doppler(payable(address(key.hooks))).isToken0();
        isUsingEth = Currency.unwrap(key.currency0) == address(0);
        asset = isToken0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        numeraire = isToken0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
    }

    function computeBuyExactOut(PoolKey calldata key, uint256 amountOut) public returns (uint256) {
        (, bool isToken0,,) = _getHookData(key);
        (int128[] memory deltaAmounts,,) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: !isToken0,
                exactAmount: uint128(amountOut),
                sqrtPriceLimitX96: !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
                hookData: ""
            })
        );

        return uint256(uint128(deltaAmounts[0]));
    }

    function computeSellExactOut(PoolKey calldata key, uint256 amountOut) public returns (uint256) {
        (, bool isToken0,,) = _getHookData(key);
        (int128[] memory deltaAmounts,,) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: isToken0,
                exactAmount: uint128(amountOut),
                sqrtPriceLimitX96: isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
                hookData: ""
            })
        );

        return uint256(uint128(deltaAmounts[0]));
    }

    /// @notice Buys asset tokens using an exact amount of numeraire tokens.
    /// @return bought Amount of asset tokens bought.
    function buyExactIn(PoolKey calldata key, uint256 amount) public payable returns (uint256 bought) {
        (bought,) = buy(key, -int256(amount));
    }

    /// @notice Buys an exact amount of asset tokens using numeraire tokens.
    function buyExactOut(PoolKey calldata key, uint256 amount) public payable returns (uint256 spent) {
        (, spent) = buy(key, int256(amount));
    }

    /// @notice Sells an exact amount of asset tokens for numeraire tokens.
    /// @return received Amount of numeraire tokens received.
    function sellExactIn(PoolKey calldata key, uint256 amount) public returns (uint256 received) {
        (, received) = sell(key, -int256(amount));
    }

    /// @notice Sells asset tokens for an exact amount of numeraire tokens.
    /// @return sold Amount of asset tokens sold.
    function sellExactOut(PoolKey calldata key, uint256 amount) public returns (uint256 sold) {
        (sold,) = sell(key, int256(amount));
    }

    /// @dev Buys a given amount of asset tokens.
    /// @param amount A negative value specificies the amount of numeraire tokens to spend,
    /// a positive value specifies the amount of asset tokens to buy.
    /// @return Amount of asset tokens bought.
    /// @return Amount of numeraire tokens used.
    function buy(PoolKey calldata key, int256 amount) public payable returns (uint256, uint256) {
        (bool isUsingEth, bool isToken0, address asset, address numeraire) = _getHookData(key);
        // Negative means exactIn, positive means exactOut.
        uint256 transferAmount = amount < 0 ? uint256(-amount) : computeBuyExactOut(key, uint256(amount));

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
    function sell(PoolKey calldata key, int256 amount) public returns (uint256, uint256) {
        (bool isUsingEth, bool isToken0, address asset, address numeraire) = _getHookData(key);
        uint256 approveAmount = amount < 0 ? uint256(-amount) : computeSellExactOut(key, uint256(amount));
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
