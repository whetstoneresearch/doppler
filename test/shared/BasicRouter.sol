// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.21;

import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { IUniversalRouter } from "@universal-router/interfaces/IUniversalRouter.sol";
import { IV4Router } from "@v4-periphery/interfaces/IV4Router.sol";
import { Commands } from "@universal-router/libraries/Commands.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { SafeCast } from "@v4-core/libraries/SafeCast.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { CalldataDecoder } from "@v4-periphery/libraries/CalldataDecoder.sol";

/// @title Basic Router
/// @notice A library for abstracting Universal Router calldata
/// @dev Useable onchain, but expensive because of encoding
/// @dev TODO: wrapper functions for the different swap types
contract BasicRouter {
    using SafeCast for *;
    using CurrencyLibrary for Currency;

    IUniversalRouter public router;

    constructor(
        address _router
    ) {
        router = IUniversalRouter(_router);
    }

    /// @notice Exact-input swaps on a single pool
    /// @param key the single pool to swap against
    /// @param zeroForOne direction of the trade, true for token0-to-token1 swaps; false otherwise
    /// @param amountIn the amount of input tokens
    /// @param amountOutMinimum the minimum amount of output tokens, reverting if the output is less than this
    /// @param hookData optional hookData to pass to `key.hooks` hook functions
    /// @param deadline the maximum allowable block.timestamp
    /// @return BalanceDelta the result of the swap
    function exactInputSingleV4(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bytes memory hookData,
        uint256 deadline
    ) public payable returns (BalanceDelta) {
        BalanceDelta before =
            toBalanceDelta(key.currency0.balanceOfSelf().toInt128(), key.currency1.balanceOfSelf().toInt128());

        (bytes memory commands, bytes[] memory inputs) =
            getExactInputSingleEncodedV4(key, zeroForOne, amountIn, amountOutMinimum, hookData);
        router.execute{ value: msg.value }(commands, inputs, deadline);

        return
            toBalanceDelta(key.currency0.balanceOfSelf().toInt128(), key.currency1.balanceOfSelf().toInt128()) - before;
    }

    /// @notice Exact-output swaps on a single pool
    /// @param key the single pool to swap against
    /// @param zeroForOne direction of the trade, true for token0-to-token1 swaps; false otherwise
    /// @param amountOut the amount of output tokens
    /// @param amountInMaximum the maximum amount of input tokens, reverting if the input is more than this
    /// @param hookData optional hookData to pass to `key.hooks` hook functions
    /// @param deadline the maximum allowable block.timestamp
    /// @return BalanceDelta the result of the swap
    function exactOutputSingleV4(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint128 amountInMaximum,
        bytes memory hookData,
        uint256 deadline
    ) public payable returns (BalanceDelta) {
        BalanceDelta before =
            toBalanceDelta(key.currency0.balanceOfSelf().toInt128(), key.currency1.balanceOfSelf().toInt128());

        (bytes memory commands, bytes[] memory inputs) =
            getExactOutputSingleEncodedV4(key, zeroForOne, amountOut, amountInMaximum, hookData);
        router.execute{ value: msg.value }(commands, inputs, deadline);

        return
            toBalanceDelta(key.currency0.balanceOfSelf().toInt128(), key.currency1.balanceOfSelf().toInt128()) - before;
    }

    /// @notice A helper function to get encoded calldata for Universal Router
    /// @return commands bytes memory, the first parameter for Universal Router `.execute()`
    /// @return inputs bytes[] memory, the second parameter for Universal Router `.execute()`, the encoded parameters
    function getExactInputSingleEncodedV4(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        bytes memory hookData
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        // UniversalRouter encoding
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](1);

        // V4Router encoding
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: hookData
            })
        );

        (Currency inputCurrency, Currency outputCurrency) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        params[1] = abi.encode(inputCurrency, uint256(amountIn)); // tokens to send (settle)
        params[2] = abi.encode(outputCurrency, uint256(amountOutMinimum)); // tokens to collect (take)

        // Universal Router argument
        inputs[0] = abi.encode(actions, params);
    }

    /// @notice A helper function to get encoded calldata for Universal Router
    /// @return commands bytes memory, the first parameter for Universal Router `.execute()`
    /// @return inputs bytes[] memory, the second parameter for Universal Router `.execute()`, the encoded parameters
    function getExactOutputSingleEncodedV4(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountOut,
        uint128 amountInMaximum,
        bytes memory hookData
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        // UniversalRouter encoding
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](1);

        // V4Router encoding
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountInMaximum,
                amountOutMinimum: amountOut,
                hookData: hookData
            })
        );

        (Currency inputCurrency, Currency outputCurrency) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        params[1] = abi.encode(inputCurrency, uint256(amountInMaximum)); // tokens to send (settle)
        params[2] = abi.encode(outputCurrency, uint256(amountOut)); // tokens to collect (take)

        // Universal Router argument
        inputs[0] = abi.encode(actions, params);
    }

    function exactInputSingleV3(
        address pool,
        address recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) public returns (BalanceDelta) {
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);

        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();
        uint24 fee = v3Pool.fee();

        IERC20(zeroForOne ? token0 : token1).transferFrom(msg.sender, address(this), amountIn);
        IERC20(zeroForOne ? token0 : token1).transfer(address(router), amountIn);

        BalanceDelta before = toBalanceDelta(
            IERC20(token0).balanceOf(address(this)).toInt128(), IERC20(token1).balanceOf(address(this)).toInt128()
        );
        bytes memory path = zeroForOne ? abi.encodePacked(token0, fee, token1) : abi.encodePacked(token1, fee, token0);

        (bytes memory commands, bytes[] memory inputs) =
            getExactInputSingleEncodedV3(recipient, path, amountIn, amountOutMinimum);
        router.execute(commands, inputs, deadline);

        return toBalanceDelta(
            IERC20(token0).balanceOf(address(this)).toInt128(), IERC20(token1).balanceOf(address(this)).toInt128()
        ) - before;
    }

    function exactOutputSingleV3(
        address pool,
        address recipient,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint256 deadline
    ) public returns (BalanceDelta) {
        IUniswapV3Pool v3Pool = IUniswapV3Pool(pool);

        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();
        uint24 fee = v3Pool.fee();

        IERC20(zeroForOne ? token0 : token1).transferFrom(msg.sender, address(this), amountInMaximum);
        IERC20(zeroForOne ? token0 : token1).transfer(address(router), amountInMaximum);

        BalanceDelta before = toBalanceDelta(
            IERC20(token0).balanceOf(address(this)).toInt128(), IERC20(token1).balanceOf(address(this)).toInt128()
        );
        // For exactOutput, reverse the path because... reasons
        bytes memory path = zeroForOne ? abi.encodePacked(token1, fee, token0) : abi.encodePacked(token0, fee, token1);

        (bytes memory commands, bytes[] memory inputs) =
            getExactOutputSingleEncodedV3(recipient, path, amountOut, amountInMaximum);
        router.execute(commands, inputs, deadline);

        return toBalanceDelta(
            IERC20(token0).balanceOf(address(this)).toInt128(), IERC20(token1).balanceOf(address(this)).toInt128()
        ) - before;
    }

    function getExactInputSingleEncodedV3(
        address recipient,
        bytes memory path,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        // UniversalRouter encoding
        commands = abi.encodePacked(uint8(Commands.V3_SWAP_EXACT_IN));
        inputs = new bytes[](1);

        // V3Router encoding
        inputs[0] = abi.encode(recipient, amountIn, amountOutMinimum, path, false);
    }

    function getExactOutputSingleEncodedV3(
        address recipient,
        bytes memory path,
        uint256 amountOut,
        uint256 amountInMaximum
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        // UniversalRouter encoding
        commands = abi.encodePacked(uint8(Commands.V3_SWAP_EXACT_OUT));
        inputs = new bytes[](1);

        // V3Router encoding
        inputs[0] = abi.encode(recipient, amountOut, amountInMaximum, path, false);
    }
}
