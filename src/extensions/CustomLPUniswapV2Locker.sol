// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { ICustomLPUniswapV2Locker } from "src/extensions/interfaces/ICustomLPUniswapV2Locker.sol";
import { CustomLPUniswapV2Migrator } from "src/extensions/CustomLPUniswapV2Migrator.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

contract CustomLPUniswapV2Locker is ICustomLPUniswapV2Locker, Ownable, ImmutableAirlock {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for uint160;

    /// @notice Address of the Uniswap V2 factory
    IUniswapV2Factory public immutable FACTORY;

    /// @notice Address of the Uniswap V2 migrator
    CustomLPUniswapV2Migrator public immutable MIGRATOR;

    /// @notice Returns the state of a pool
    mapping(address pool => PoolState state) public getState;

    /**
     * @param factory_ Address of the Uniswap V2 factory
     * @param migrator_ Address of the Uniswap V2 migrator
     */
    constructor(
        address airlock_,
        IUniswapV2Factory factory_,
        CustomLPUniswapV2Migrator migrator_,
        address owner_
    ) Ownable(owner_) ImmutableAirlock(airlock_) {
        FACTORY = factory_;
        MIGRATOR = migrator_;
    }

    /**
     * @notice Locks the LP tokens held by this contract with custom lock up period
     * @param pool Address of the Uniswap V2 pool
     * @param recipient Address of the recipient
     * @param lockPeriod Duration of the lock period
     */
    function receiveAndLock(address pool, address recipient, uint32 lockPeriod) external {
        require(msg.sender == address(MIGRATOR), SenderNotMigrator());
        require(getState[pool].minUnlockDate == 0, PoolAlreadyInitialized());

        uint256 balance = IUniswapV2Pair(pool).balanceOf(address(this));
        require(balance > 0, NoBalanceToLock());

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();
        uint256 supply = IUniswapV2Pair(pool).totalSupply();

        uint112 amount0 = uint112((balance * reserve0) / supply);
        uint112 amount1 = uint112((balance * reserve1) / supply);

        getState[pool] = PoolState({
            amount0: amount0,
            amount1: amount1,
            minUnlockDate: uint32(block.timestamp + lockPeriod),
            recipient: recipient
        });
    }

    /**
     * @notice Unlocks the LP tokens by burning them, fees are sent to the owner
     * and the principal tokens to the recipient i.e. Timelock contract by default
     * @param pool Address of the pool
     */
    function claimFeesAndExit(
        address pool
    ) external {
        PoolState memory state = getState[pool];

        require(state.minUnlockDate > 0, PoolNotInitialized());
        require(block.timestamp >= state.minUnlockDate, MinUnlockDateNotReached());

        // get previous reserves and share of invariant
        uint256 kLast = uint256(state.amount0) * uint256(state.amount1);

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();

        uint256 balance = IUniswapV2Pair(pool).balanceOf(address(this));
        IUniswapV2Pair(pool).transfer(pool, balance);

        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pool).burn(address(this));

        uint256 position0 = kLast.mulDivDown(reserve0, reserve1).sqrt();
        uint256 position1 = kLast.mulDivDown(reserve1, reserve0).sqrt();

        uint256 fees0 = amount0 > position0 ? amount0 - position0 : 0;
        uint256 fees1 = amount1 > position1 ? amount1 - position1 : 0;

        address token0 = IUniswapV2Pair(pool).token0();
        address token1 = IUniswapV2Pair(pool).token1();

        if (fees0 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token0), owner(), fees0);
        }
        if (fees1 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token1), owner(), fees1);
        }

        uint256 principal0 = fees0 > 0 ? amount0 - fees0 : amount0;
        uint256 principal1 = fees1 > 0 ? amount1 - fees1 : amount1;

        if (principal0 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token0), state.recipient, principal0);
        }
        if (principal1 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token1), state.recipient, principal1);
        }
    }
}
