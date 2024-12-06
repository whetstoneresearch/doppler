/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager, PoolKey } from "v4-core/src/PoolManager.sol";
import { lessThan, Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Doppler } from "src/Doppler.sol";

error NotAirlock();

error InvalidPoolKey();

error TokenNotInPoolKey();

error HookNotInPoolKey();

contract UniswapV4Initializer is IPoolInitializer {
    using CurrencyLibrary for Currency;

    address public immutable airlock;
    IPoolManager public immutable poolManager;

    constructor(address airlock_, IPoolManager poolManager_) {
        airlock = airlock_;
        poolManager = poolManager_;
    }

    function initialize(uint256 numTokensToSell, bytes32 salt, bytes memory data) external returns (address) {
        if (msg.sender != airlock) {
            revert NotAirlock();
        }

        /*
        require(
            asset == Currency.unwrap(poolKey.currency0) || asset == Currency.unwrap(poolKey.currency1),
            TokenNotInPoolKey()
        );
        require(hook == address(poolKey.hooks), HookNotInPoolKey());
        */

        (
            PoolKey memory poolKey,
            uint160 sqrtPriceX96,
            uint256 minimumProceeds,
            uint256 maximumProceeds,
            uint256 startingTime,
            uint256 endingTime,
            int24 startingTick,
            int24 endingTick,
            uint256 epochLength,
            int24 gamma,
            bool isToken0,
            uint256 numPDSlugs
        ) = abi.decode(
            data, (PoolKey, uint160, uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256)
        );

        require(lessThan(poolKey.currency0, poolKey.currency1), InvalidPoolKey());

        poolManager.initialize(poolKey, sqrtPriceX96, new bytes(0));

        return address(
            new Doppler{ salt: salt }(
                poolManager,
                numTokensToSell,
                minimumProceeds,
                maximumProceeds,
                startingTime,
                endingTime,
                startingTick,
                endingTick,
                epochLength,
                gamma,
                isToken0,
                numPDSlugs,
                airlock
            )
        );
    }

    function exitLiquidity() external { }
}
