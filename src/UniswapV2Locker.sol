/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { SafeTransferLib, ERC20 } from "solmate/src/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "solmate/src/tokens/WETH.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { AssetData, Airlock } from "src/Airlock.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Router02 } from "src/interfaces/IUniswapV2Router02.sol";

uint256 constant WAD = 1e18;

// todo: think about minUnlockDate
// 2106 problem?
struct PoolState {
    uint112 amount0;
    uint112 amount1;
    bool initialized;
}

contract UniswapV2Locker {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for uint160;

    IUniswapV2Factory public immutable factory;
    IWETH public immutable weth;
    Airlock public immutable airlock;
    ILiquidityMigrator public immutable migrator;

    /// @notice Returns the state of a pool
    mapping(address pool => PoolState state) public getState;

    /**
     * @param factory_ Address of the Uniswap V2 factory
     */
    constructor(Airlock airlock_, IUniswapV2Factory factory_, ILiquidityMigrator migrator_) {
        airlock = airlock_;
        factory = factory_;
        migrator = migrator_;
    }

    function receiveAndLock(
        address pool
    ) external {
        require(getState[pool].initialized == false, "UniswapV2Locker: Pool already initialized");

        uint256 balance = IUniswapV2Pair(pool).balanceOf(address(this));
        require(balance > 0, "UniswapV2Locker: No balance to lock");

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();
        uint256 supply = IUniswapV2Pair(pool).totalSupply();

        // todo: check this type cast
        uint112 amount0 = uint112((balance * reserve0) / supply);
        uint112 amount1 = uint112((balance * reserve1) / supply);

        getState[pool] = PoolState({ amount0: amount0, amount1: amount1, initialized: true });
    }

    // todo: add exit blocker for only owner
    function claimFeesAndExit(
        address pool
    ) external returns (uint112, uint112) {
        PoolState memory state = getState[pool];

        require(state.initialized, "UniswapV2Locker: Pool not initialized");

        // get previous reserves and share of invariant
        uint256 kLast = uint256(state.amount0) * uint256(state.amount1);

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();

        uint256 balance = IUniswapV2Pair(pool).balanceOf(address(this));
        IUniswapV2Pair(pool).transfer(pool, balance);

        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pool).burn(address(this));

        // TODO: Check out the rounding direction
        uint256 position0 = FixedPointMathLib.sqrt(FixedPointMathLib.mulDivDown(kLast, reserve0, reserve1));
        uint256 position1 = FixedPointMathLib.sqrt(FixedPointMathLib.mulDivDown(kLast, reserve1, reserve0));

        uint256 fees0 = amount0 > position0 ? amount0 - position0 : 0;
        uint256 fees1 = amount1 > position1 ? amount1 - position1 : 0;

        address token0 = IUniswapV2Pair(pool).token0();
        address token1 = IUniswapV2Pair(pool).token1();

        address owner = airlock.owner();
        if (fees0 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token0), owner, fees0);
        }
        if (fees1 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token1), owner, fees1);
        }

        uint256 principal0 = fees0 > 0 ? amount0 - fees0 : amount0;
        uint256 principal1 = fees1 > 0 ? amount1 - fees1 : amount1;

        // address timelock = ILiquidityMigrator(airlock).getAssetData(pool).timelock;

        if (fees0 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token0), owner, fees0);
        }
        if (fees1 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token1), owner, fees1);
        }
    }
}
