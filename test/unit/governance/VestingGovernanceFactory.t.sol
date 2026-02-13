// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Test } from "forge-std/Test.sol";
import {
    InvalidFactoryGraceDuration,
    InvalidBeneficiary,
    VestingGovernanceData,
    VestingGovernanceFactory
} from "src/governance/VestingGovernanceFactory.sol";
import { InvalidInitializerKind, VestingMiddleware } from "src/governance/VestingMiddleware.sol";
import { DEAD_ADDRESS } from "src/types/Constants.sol";

contract DummyPoolManager { }

contract VestingGovernanceFactoryTest is Test {
    uint32 internal constant FACTORY_GRACE = 5 minutes;
    uint8 internal constant DOPPLER_HOOK_INITIALIZER_KIND = 1;

    VestingGovernanceFactory internal factory;

    address internal airlock = makeAddr("airlock");
    address internal asset = makeAddr("asset");
    address internal launchpadAdmin = makeAddr("launchpadAdmin");
    address internal beneficiary = makeAddr("beneficiary");
    address internal governanceExecutor = makeAddr("governanceExecutor");
    address internal numeraire = makeAddr("numeraire");

    function setUp() public {
        factory = new VestingGovernanceFactory(airlock, IPoolManager(address(new DummyPoolManager())), FACTORY_GRACE);
    }

    function test_constructor_RevertsWhenGraceDurationBelowMinimum() public {
        IPoolManager poolManager = IPoolManager(address(new DummyPoolManager()));
        vm.expectRevert(abi.encodeWithSelector(InvalidFactoryGraceDuration.selector, uint32(4 minutes)));
        new VestingGovernanceFactory(airlock, poolManager, 4 minutes);
    }

    function test_create_DeploysMiddlewareAndReturnsDeadGovernance() public {
        VestingGovernanceData memory data = VestingGovernanceData({
            launchpadAdmin: launchpadAdmin,
            beneficiary: beneficiary,
            governanceExecutor: governanceExecutor,
            streamStart: uint64(block.timestamp + 1 days),
            periodDuration: 14 days,
            numeraire: numeraire,
            initializerKind: DOPPLER_HOOK_INITIALIZER_KIND
        });

        vm.prank(airlock);
        (address governance, address timelock) = factory.create(asset, abi.encode(data));

        assertEq(governance, DEAD_ADDRESS, "governance should be DEAD_ADDRESS");
        assertTrue(timelock != address(0), "middleware should be deployed");

        VestingMiddleware middleware = VestingMiddleware(payable(timelock));
        assertEq(middleware.owner(), launchpadAdmin, "owner mismatch");
        assertEq(middleware.asset(), asset, "asset mismatch");
        assertEq(middleware.numeraire(), numeraire, "numeraire mismatch");
        assertEq(middleware.beneficiary(), beneficiary, "beneficiary mismatch");
        assertEq(middleware.governanceExecutor(), governanceExecutor, "executor mismatch");
        assertEq(middleware.streamStart(), data.streamStart, "streamStart mismatch");
        assertEq(middleware.periodDuration(), data.periodDuration, "period duration mismatch");
        assertEq(middleware.graceDuration(), FACTORY_GRACE, "grace duration mismatch");
        assertEq(uint8(middleware.initializerKind()), DOPPLER_HOOK_INITIALIZER_KIND, "initializer kind mismatch");
    }

    function test_create_DefaultsStreamStartToCurrentBlockTimeWhenZero() public {
        VestingGovernanceData memory data = VestingGovernanceData({
            launchpadAdmin: launchpadAdmin,
            beneficiary: beneficiary,
            governanceExecutor: address(0),
            streamStart: 0,
            periodDuration: 14 days,
            numeraire: numeraire,
            initializerKind: DOPPLER_HOOK_INITIALIZER_KIND
        });

        uint64 expected = uint64(block.timestamp);
        vm.prank(airlock);
        (, address timelock) = factory.create(asset, abi.encode(data));

        VestingMiddleware middleware = VestingMiddleware(payable(timelock));
        assertEq(middleware.streamStart(), expected, "streamStart default mismatch");
        assertEq(middleware.governanceExecutor(), launchpadAdmin, "executor should default to owner");
    }

    function test_create_ZeroLaunchpadAdmin_DisablesAdminCommands() public {
        VestingGovernanceData memory data = VestingGovernanceData({
            launchpadAdmin: address(0),
            beneficiary: beneficiary,
            governanceExecutor: governanceExecutor,
            streamStart: uint64(block.timestamp),
            periodDuration: 14 days,
            numeraire: numeraire,
            initializerKind: DOPPLER_HOOK_INITIALIZER_KIND
        });

        vm.prank(airlock);
        (, address timelock) = factory.create(asset, abi.encode(data));

        VestingMiddleware middleware = VestingMiddleware(payable(timelock));
        assertEq(middleware.owner(), timelock, "owner should be middleware in no-admin mode");
        assertEq(middleware.governanceExecutor(), timelock, "executor should be middleware in no-admin mode");

        vm.expectRevert();
        vm.prank(launchpadAdmin);
        middleware.queueSellInstruction(0, 1e18);

        vm.expectRevert();
        vm.prank(governanceExecutor);
        middleware.setGovernanceExecutor(governanceExecutor);
    }

    function test_create_RevertWhenBeneficiaryZero() public {
        VestingGovernanceData memory data = VestingGovernanceData({
            launchpadAdmin: launchpadAdmin,
            beneficiary: address(0),
            governanceExecutor: governanceExecutor,
            streamStart: uint64(block.timestamp),
            periodDuration: 14 days,
            numeraire: numeraire,
            initializerKind: DOPPLER_HOOK_INITIALIZER_KIND
        });

        vm.prank(airlock);
        vm.expectRevert(InvalidBeneficiary.selector);
        factory.create(asset, abi.encode(data));
    }

    function test_create_RevertWhenNotAirlock() public {
        VestingGovernanceData memory data = VestingGovernanceData({
            launchpadAdmin: launchpadAdmin,
            beneficiary: beneficiary,
            governanceExecutor: governanceExecutor,
            streamStart: uint64(block.timestamp),
            periodDuration: 14 days,
            numeraire: numeraire,
            initializerKind: DOPPLER_HOOK_INITIALIZER_KIND
        });

        vm.expectRevert();
        factory.create(asset, abi.encode(data));
    }

    function test_create_RevertWhenInitializerKindInvalid() public {
        VestingGovernanceData memory data = VestingGovernanceData({
            launchpadAdmin: launchpadAdmin,
            beneficiary: beneficiary,
            governanceExecutor: governanceExecutor,
            streamStart: uint64(block.timestamp),
            periodDuration: 14 days,
            numeraire: numeraire,
            initializerKind: 2
        });

        vm.prank(airlock);
        vm.expectRevert(abi.encodeWithSelector(InvalidInitializerKind.selector, uint8(2)));
        factory.create(asset, abi.encode(data));
    }
}
