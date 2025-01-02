/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager, PoolKey, IHooks } from "v4-core/src/PoolManager.sol";
import { lessThan, Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Doppler } from "src/Doppler.sol";

error NotAirlock();

error InvalidPoolKey();

error TokenNotInPoolKey();

error HookNotInPoolKey();

contract DopplerDeployer {
    // These variables are purposely not immutable to avoid hitting the contract size limit
    address public airlock;
    IPoolManager public poolManager;

    constructor(address airlock_, IPoolManager poolManager_) {
        poolManager = poolManager_;
        airlock = airlock_;
    }

    function deploy(uint256 numTokensToSell, bytes32 salt, bytes calldata data) external returns (Doppler) {
        (
            ,
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
        ) = abi.decode(data, (uint160, uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256));

        Doppler doppler = new Doppler{ salt: salt }(
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
        );

        return doppler;
    }
}

contract UniswapV4Initializer is IPoolInitializer {
    using CurrencyLibrary for Currency;

    address public immutable airlock;
    IPoolManager public immutable poolManager;
    DopplerDeployer public immutable deployer;

    constructor(address airlock_, IPoolManager poolManager_, DopplerDeployer deployer_) {
        airlock = airlock_;
        poolManager = poolManager_;
        deployer = deployer_;
    }

    function initialize(
        address asset,
        address numeraire,
        uint256 numTokensToSell,
        bytes32 salt,
        bytes calldata data
    ) external returns (address) {
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

        (uint160 sqrtPriceX96,,,,,,,,, bool isToken0,) =
            abi.decode(data, (uint160, uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256));

        Doppler doppler = deployer.deploy(numTokensToSell, salt, data);

        PoolKey memory poolKey = PoolKey({
            currency0: isToken0 ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: isToken0 ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: IHooks(doppler),
            fee: 3000,
            tickSpacing: 60
        });

        // require(lessThan(poolKey.currency0, poolKey.currency1), InvalidPoolKey());

        poolManager.initialize(poolKey, sqrtPriceX96);

        return address(doppler);
    }

    function exitLiquidity(
        address asset
    )
        external
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        )
    { }
}
