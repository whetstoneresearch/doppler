// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { CustomLPUniswapV2Migrator } from "src/extensions/CustomLPUniswapV2Migrator.sol";
import { UniswapV2Locker } from "src/UniswapV2Locker.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

contract CustomLPUniswapV2Locker is UniswapV2Locker {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for uint160;

    /**
     * @param factory_ Address of the Uniswap V2 factory
     * @param migrator_ Address of the Uniswap V2 migrator
     */
    constructor(
        address airlock_,
        IUniswapV2Factory factory_,
        CustomLPUniswapV2Migrator migrator_,
        address owner_
    ) UniswapV2Locker(airlock_, factory_, migrator_, owner_) { }

    /**
     * @notice Locks the LP tokens held by this contract with custom lock up period
     * @param pool Address of the Uniswap V2 pool
     * @param recipient Address of the recipient
     * @param lockPeriod Duration of the lock period
     */
    function receiveAndLock(address pool, address recipient, uint32 lockPeriod) external {
        require(msg.sender == address(migrator), SenderNotMigrator());
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
}
