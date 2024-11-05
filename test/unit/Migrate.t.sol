pragma solidity 0.8.26;

import { BaseTest } from "test/shared/BaseTest.sol";
import { SenderNotAirlock, CannotMigrate } from "src/Doppler.sol";
import { StateLibrary, IPoolManager, PoolId } from "v4-core/src/libraries/StateLibrary.sol";

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
}
