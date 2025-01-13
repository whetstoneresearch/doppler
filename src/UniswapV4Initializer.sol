/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { IPoolManager, PoolKey, IHooks } from "v4-core/src/PoolManager.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { Doppler } from "src/Doppler.sol";
import { DERC20 } from "src/DERC20.sol";

error OnlyAirlock();

error InvalidPoolKey();

error TokenNotInPoolKey();

error HookNotInPoolKey();

error InvalidTokenOrder();

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

/**
 * @title Uniswap V4 Initializer
 * @notice Initializes a Uniswap V4 pool with an associated Doppler contract as a hook
 * @custom:security-contact security@whetstone.cc
 */
contract UniswapV4Initializer is IPoolInitializer {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for address;

    /// @notice Address of the Airlock contract
    address public immutable airlock;

    /// @notice Address of the Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Address of the DopplerDeployer contract
    DopplerDeployer public immutable deployer;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param poolManager_ Address of the Uniswap V4 PoolManager
     * @param deployer_ Address of the DopplerDeployer contract
     */
    constructor(address airlock_, IPoolManager poolManager_, DopplerDeployer deployer_) {
        airlock = airlock_;
        poolManager = poolManager_;
        deployer = deployer_;
    }

    /// @inheritdoc IPoolInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 numTokensToSell,
        bytes32 salt,
        bytes calldata data
    ) external returns (address) {
        if (msg.sender != airlock) {
            revert OnlyAirlock();
        }

        (uint160 sqrtPriceX96,,,,,,,,, bool isToken0,) =
            abi.decode(data, (uint160, uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256));

        Doppler doppler = deployer.deploy(numTokensToSell, salt, data);

        if (isToken0 && asset > numeraire || !isToken0 && asset < numeraire) {
            revert InvalidTokenOrder();
        }

        PoolKey memory poolKey = PoolKey({
            currency0: isToken0 ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: isToken0 ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: IHooks(doppler),
            fee: 3000,
            tickSpacing: 8
        });

        if (asset != Currency.unwrap(poolKey.currency0) && asset != Currency.unwrap(poolKey.currency1)) {
            revert TokenNotInPoolKey();
        }

        if (address(doppler) != address(poolKey.hooks)) {
            revert HookNotInPoolKey();
        }

        DERC20 token = DERC20(asset);
        address(token).safeTransferFrom(address(airlock), address(doppler), numTokensToSell);

        poolManager.initialize(poolKey, sqrtPriceX96);

        return address(doppler);
    }

    /// @inheritdoc IPoolInitializer
    function exitLiquidity(
        address hook
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
    {
        if (msg.sender != airlock) {
            revert OnlyAirlock();
        }

        (sqrtPriceX96, token0, fees0, balance0, token1, fees1, balance1) = Doppler(payable(hook)).migrate(airlock);
    }
}
