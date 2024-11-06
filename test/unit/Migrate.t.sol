pragma solidity 0.8.26;

import { console } from "forge-std/console.sol";
import { StateLibrary, IPoolManager, PoolId } from "v4-core/src/libraries/StateLibrary.sol";
import { SenderNotAirlock, CannotMigrate } from "src/Doppler.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { BaseTest } from "test/shared/BaseTest.sol";

contract MigrateTest is BaseTest {
    using StateLibrary for IPoolManager;

    function test_migrate_RevertsIfSenderNotAirlock() public {
        vm.expectRevert(SenderNotAirlock.selector);
        hook.migrate();
    }

    function test_migrate_RevertsIfConditionsNotMet() public {
        vm.startPrank(hook.airlock());
        vm.expectRevert(CannotMigrate.selector);
        hook.migrate();
    }

    function test_migrate_RemovesAllLiquidity() public {
        uint256 numPDSlugs = hook.getNumPDSlugs();

        vm.warp(hook.getStartingTime());
        buyExactOut(hook.getNumTokensToSell());

        vm.warp(hook.getEndingTime());
        vm.prank(hook.airlock());
        hook.migrate();

        for (uint256 i = 1; i < numPDSlugs + 3; i++) {
            (int24 tickLower, int24 tickUpper,,) = hook.positions(bytes32(i));
            (uint128 liquidity,,) = manager.getPositionInfo(
                poolId, address(hook), isToken0 ? tickLower : tickUpper, isToken0 ? tickUpper : tickLower, bytes32(i)
            );
            assertEq(liquidity, 0, "liquidity should be 0");
        }
    }

    function test_migrate_NoMoreFundsInHook() public {
        console.log("In Pool %e", ERC20(isToken0 ? token0 : token1).balanceOf(address(manager)));

        uint256 preBalance = ERC20(isToken0 ? token0 : token1).balanceOf(address(hook));
        console.log("preBalance %e", preBalance);

        vm.warp(hook.getStartingTime());

        _debugPositions("Initial positions");

        buyExactOut(1 ether);
        console.log("In Pool %e", ERC20(isToken0 ? token0 : token1).balanceOf(address(manager)));

        _debugPositions("After swap");

        buyExactOut(hook.getNumTokensToSell() - 1);

        _debugPositions("After swap 2");

        uint256 midBalance = ERC20(isToken0 ? token0 : token1).balanceOf(address(hook));
        console.log("midBalance %e", midBalance);

        vm.warp(hook.getEndingTime());
        vm.prank(hook.airlock());
        hook.migrate();

        _debugPositions("After migration");

        if (usingEth) {
            assertEq(address(hook).balance, 0, "hook should have no ETH");
        } else {
            assertEq(ERC20(token0).balanceOf(address(hook)), 0, "hook should have no token0");
        }

        assertEq(ERC20(token1).balanceOf(address(hook)), 0, "hook should have no token1");
    }
}
