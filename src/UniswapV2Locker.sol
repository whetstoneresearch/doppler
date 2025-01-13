/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "solmate/src/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { Airlock } from "src/Airlock.sol";
import { IUniswapV2Pair } from "src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Factory } from "src/interfaces/IUniswapV2Factory.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";

/// @notice Thrown when the sender is not the migrator contract
error SenderNotMigrator();

/// @notice Thrown when trying to initialized a pool that was already initialized
error PoolAlreadyInitialized();

/// @notice Thrown when trying to exit a pool that was not initialized
error PoolNotInitialized();

/// @notice Thrown when the Locker contract doesn't hold any LP tokens
error NoBalanceToLock();

// todo: think about minUnlockDate
// 2106 problem?

/**
 * @notice State of a pool
 * @param amount0 Reserve of token0
 * @param amount1 Reserve of token1
 * @param initialized Whether the pool has been initialized
 */
struct PoolState {
    uint112 amount0;
    uint112 amount1;
    bool initialized;
}

contract UniswapV2Locker is Ownable {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for uint160;

    /// @notice Address of the Uniswap V2 factory
    IUniswapV2Factory public immutable factory;

    /// @notice Address of the Airlock contract
    Airlock public immutable airlock;

    /// @notice Address of the Uniswap V2 migrator
    UniswapV2Migrator public immutable migrator;

    /// @notice Returns the state of a pool
    mapping(address pool => PoolState state) public getState;

    /**
     * @param factory_ Address of the Uniswap V2 factory
     */
    constructor(Airlock airlock_, IUniswapV2Factory factory_, UniswapV2Migrator migrator_) Ownable(msg.sender) {
        airlock = airlock_;
        factory = factory_;
        migrator = migrator_;
    }

    /**
     * @notice Locks the LP tokens held by this contract
     * @param pool Address of the pool
     */
    function receiveAndLock(
        address pool
    ) external {
        require(msg.sender == address(migrator), SenderNotMigrator());
        require(getState[pool].initialized == false, PoolAlreadyInitialized());

        uint256 balance = IUniswapV2Pair(pool).balanceOf(address(this));
        require(balance > 0, NoBalanceToLock());

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();
        uint256 supply = IUniswapV2Pair(pool).totalSupply();

        // todo: check this type cast
        uint112 amount0 = uint112((balance * reserve0) / supply);
        uint112 amount1 = uint112((balance * reserve1) / supply);

        getState[pool] = PoolState({ amount0: amount0, amount1: amount1, initialized: true });
    }

    /**
     * @notice Unlocks the LP tokens by burning them, fees are sent to the Airlock owner
     * and the principal tokens to the timelock contract
     * @param pool Address of the pool
     */
    function claimFeesAndExit(
        address pool
    ) external onlyOwner {
        PoolState memory state = getState[pool];

        require(state.initialized, PoolNotInitialized());

        // get previous reserves and share of invariant
        uint256 kLast = uint256(state.amount0) * uint256(state.amount1);

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pool).getReserves();

        uint256 balance = IUniswapV2Pair(pool).balanceOf(address(this));
        IUniswapV2Pair(pool).transfer(pool, balance);

        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pool).burn(address(this));

        // TODO: Check out the rounding direction
        uint256 position0 = kLast.mulDivDown(reserve0, reserve1).sqrt();
        uint256 position1 = kLast.mulDivDown(reserve1, reserve0).sqrt();

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

        (, address timelock,,,,,,,,) = airlock.getAssetData(migrator.getAsset(pool));
        if (principal0 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token0), timelock, principal0);
        }
        if (principal1 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token1), timelock, principal1);
        }
    }
}
