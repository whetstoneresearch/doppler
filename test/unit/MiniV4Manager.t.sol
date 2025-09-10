// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { console } from "forge-std/console.sol";

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Constants } from "@v4-core-test/utils/Constants.sol";
import { LiquidityAmounts } from "@v4-periphery/libraries/LiquidityAmounts.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";

import { MiniV4Manager, CallerNotPoolManager } from "src/base/MiniV4Manager.sol";
import { Position } from "src/types/Position.sol";

contract MiniV4ManagerImplementation is MiniV4Manager {
    constructor(
        IPoolManager poolManager_
    ) MiniV4Manager(poolManager_) { }

    function mint(PoolKey memory poolKey, Position[] memory positions) external returns (BalanceDelta) {
        return _mint(poolKey, positions);
    }

    function burn(PoolKey memory poolKey, Position[] memory positions) external returns (BalanceDelta, BalanceDelta) {
        return _burn(poolKey, positions);
    }

    function collect(PoolKey memory poolKey, Position[] memory positions) external returns (BalanceDelta) {
        return _collect(poolKey, positions);
    }
}

contract MiniV4ManagerTest is Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    MiniV4ManagerImplementation public mini;

    PoolKey public poolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            tickSpacing: 1,
            fee: 3000,
            hooks: IHooks(address(0))
        });
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        mini = new MiniV4ManagerImplementation(manager);
        currency0.transfer(address(mini), currency0.balanceOfSelf() / 2);
        currency1.transfer(address(mini), currency1.balanceOfSelf() / 2);
    }

    function test_constructor() public view {
        assertEq(address(mini.poolManager()), address(manager), "Wrong PoolManager address");
    }

    function test_unlockCallback_RevertsIfSenderNotPoolManager() public {
        vm.expectRevert(CallerNotPoolManager.selector);
        mini.unlockCallback(new bytes(0));
    }

    function test_mint() public returns (Position[] memory positions) {
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-1000), TickMath.getSqrtPriceAtTick(1000), 1e18, 1e18
        );

        positions = new Position[](1);
        positions[0] = Position({ tickLower: -1000, tickUpper: 1000, liquidity: liquidity, salt: bytes32(0) });

        (BalanceDelta balanceDelta) = mini.mint(poolKey, positions);
        assertEq(balanceDelta.amount0(), -1e18, "Wrong balance0 delta");
        assertEq(balanceDelta.amount1(), -1e18, "Wrong balance1 delta");

        uint128 poolLiquidity = manager.getLiquidity(poolKey.toId());
        assertEq(liquidity, poolLiquidity, "Incorrect pool liquidity");

        (uint128 positionLiquidity,,) = manager.getPositionInfo(poolKey.toId(), address(mini), -1000, 1000, 0);
        assertEq(liquidity, positionLiquidity, "Incorrect position liquidity");
    }

    function test_collect() public {
        Position[] memory positions = test_mint();

        int128 swapAmount = -0.1e18;

        swap(swapAmount, true);
        BalanceDelta feesAccrued = mini.collect(poolKey, positions);
        assertGt(feesAccrued.amount0(), 0, "Incorrect fees0");
        assertEq(feesAccrued.amount1(), 0, "Incorrect fees1");

        swap(swapAmount, false);
        feesAccrued = mini.collect(poolKey, positions);
        assertEq(feesAccrued.amount0(), 0, "Incorrect fees0");
        assertGt(feesAccrued.amount1(), 0, "Incorrect fees1");
    }

    function test_burn() public {
        Position[] memory positions = test_mint();

        int128 swapAmount = -0.1e18;
        BalanceDelta swapBalanceDelta = swap(swapAmount, true);
        swap(swapBalanceDelta.amount1(), false);

        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = mini.burn(poolKey, positions);

        console.log("balanceDelta0", balanceDelta.amount0());
        console.log("balanceDelta1", balanceDelta.amount1());
        console.log("feesAccrued0", feesAccrued.amount0());
        console.log("feesAccrued1", feesAccrued.amount1());
    }

    function swap(int128 amountSpecified, bool zeroForOne) internal returns (BalanceDelta balanceDelta) {
        return swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            new bytes(0)
        );
    }
}
