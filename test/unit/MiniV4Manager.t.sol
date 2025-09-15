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
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";

import { MiniV4Manager, CallerNotPoolManager } from "src/base/MiniV4Manager.sol";
import { Position } from "src/types/Position.sol";

/// @dev Obviously not for production use, these functions should never be exposed without access control
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
    uint128 amount0 = 1e18;
    uint128 amount1 = 1e18;

    function setUp() public {
        deployFreshManagerAndRouters();
        mini = new MiniV4ManagerImplementation(manager);
    }

    function test_constructor() public view {
        assertEq(address(mini.poolManager()), address(manager), "Wrong PoolManager address");
    }

    function test_unlockCallback_RevertsIfSenderNotPoolManager() public {
        vm.expectRevert(CallerNotPoolManager.selector);
        mini.unlockCallback(new bytes(0));
    }

    function test_mint() public returns (Position[] memory) {
        _setUpTokens();
        return _mint();
    }

    function test_mintWithETH() public returns (Position[] memory) {
        _setUpEth();
        return _mint();
    }

    function _mint() public returns (Position[] memory positions) {
        positions = new Position[](4);
        uint128 totalLiquidity;

        for (uint256 i; i < 4; ++i) {
            int24 tickLower = -1000 * int24(uint24(i + 1));
            int24 tickUpper = -tickLower;

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                Constants.SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                amount0,
                amount1
            );

            totalLiquidity += liquidity;
            positions[i] =
                Position({ tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity, salt: bytes32(i) });
        }

        (BalanceDelta balanceDelta) = mini.mint(poolKey, positions);
        assertEq(balanceDelta.amount0(), -int128(amount0 * 4), "Wrong balance0 delta");
        assertEq(balanceDelta.amount1(), -int128(amount1 * 4), "Wrong balance1 delta");

        uint128 poolLiquidity = manager.getLiquidity(poolKey.toId());
        assertEq(totalLiquidity, poolLiquidity, "Incorrect pool liquidity");

        for (uint256 i; i != positions.length; ++i) {
            Position memory pos = positions[i];
            (uint128 positionLiquidity,,) =
                manager.getPositionInfo(poolKey.toId(), address(mini), pos.tickLower, pos.tickUpper, pos.salt);
            assertEq(pos.liquidity, positionLiquidity, "Incorrect position liquidity");
        }
    }

    function test_collect() public {
        Position[] memory positions = test_mint();

        int128 swapAmount = -0.1e18;

        _swap(swapAmount, true, false);
        BalanceDelta feesAccrued = mini.collect(poolKey, positions);
        assertGt(feesAccrued.amount0(), 0, "Incorrect fees0");
        assertEq(feesAccrued.amount1(), 0, "Incorrect fees1");

        _swap(swapAmount, false, false);
        feesAccrued = mini.collect(poolKey, positions);
        assertEq(feesAccrued.amount0(), 0, "Incorrect fees0");
        assertGt(feesAccrued.amount1(), 0, "Incorrect fees1");
    }

    function test_collectWithEth() public {
        Position[] memory positions = test_mint();

        int128 swapAmount = -0.1e18;

        _swap(swapAmount, true, true);
        BalanceDelta feesAccrued = mini.collect(poolKey, positions);
        assertGt(feesAccrued.amount0(), 0, "Incorrect fees0");
        assertEq(feesAccrued.amount1(), 0, "Incorrect fees1");

        _swap(swapAmount, false, true);
        feesAccrued = mini.collect(poolKey, positions);
        assertEq(feesAccrued.amount0(), 0, "Incorrect fees0");
        assertGt(feesAccrued.amount1(), 0, "Incorrect fees1");
    }

    function test_burn() public {
        Position[] memory positions = test_mint();

        int128 swapAmount = -0.1e18;
        _swap(swapAmount, true, false);
        _swap(swapAmount, false, false);

        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = mini.burn(poolKey, positions);
        assertGt(balanceDelta.amount0(), 0, "Incorrect balanceDelta0");
        assertGt(balanceDelta.amount1(), 0, "Incorrect balanceDelta1");
        assertGt(feesAccrued.amount0(), 0, "Incorrect fees0");
        assertGt(feesAccrued.amount1(), 0, "Incorrect fees1");
    }

    function test_burnWithEth() public {
        Position[] memory positions = test_mint();

        int128 swapAmount = -0.1e18;
        _swap(swapAmount, true, true);
        _swap(swapAmount, false, true);

        (BalanceDelta balanceDelta, BalanceDelta feesAccrued) = mini.burn(poolKey, positions);
        assertGt(balanceDelta.amount0(), 0, "Incorrect balanceDelta0");
        assertGt(balanceDelta.amount1(), 0, "Incorrect balanceDelta1");
        assertGt(feesAccrued.amount0(), 0, "Incorrect fees0");
        assertGt(feesAccrued.amount1(), 0, "Incorrect fees1");
    }

    function _setUpTokens() internal {
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
        currency0.transfer(address(mini), amount0 * 4);
        currency1.transfer(address(mini), amount1 * 4);
    }

    function _setUpEth() internal {
        currency1 = deployMintAndApproveCurrency();
        vm.label(Currency.unwrap(currency1), "Currency1");

        poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            tickSpacing: 1,
            fee: 3000,
            hooks: IHooks(address(0))
        });
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        vm.deal(address(mini), amount0 * 4);
        currency1.transfer(address(mini), amount1 * 4);
    }

    function _swap(int128 amountSpecified, bool zeroForOne, bool useEth) internal returns (BalanceDelta balanceDelta) {
        if (useEth) {
            // Not entirely correct since a positive amountSpecified means exact output, but fine for testing
            vm.deal(address(this), uint128(-amountSpecified));
        } else {
            // No need to mint more tokens since all the initial supply is already in this contract
        }

        return swapRouter.swap{ value: useEth ? uint128(-amountSpecified) : 0 }(
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
