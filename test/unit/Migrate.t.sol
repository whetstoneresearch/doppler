pragma solidity 0.8.26;

import { BaseTest } from "test/shared/BaseTest.sol";
import { SenderNotAirlock } from "src/Doppler.sol";

contract MigrateTest is BaseTest {
    function test_migrate_RevertsIfSenderNotAirlock() public {
        vm.expectRevert(SenderNotAirlock.selector);
        hook.migrate();
    }
}
