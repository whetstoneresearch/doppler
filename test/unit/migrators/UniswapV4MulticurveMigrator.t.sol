// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Constants } from "@uniswap/v4-core/test/utils/Constants.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";

import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { UniswapV4MigratorHook } from "src/migrators/UniswapV4MigratorHook.sol";
import { UniswapV4MulticurveMigrator } from "src/migrators/UniswapV4MulticurveMigrator.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract AirlockMock {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

contract UniswapV4MulticurveMigratorTest is Deployers {
    address public owner = makeAddr("Owner");
    address public recipient = makeAddr("Recipient");

    AirlockMock public airlock;
    UniswapV4MulticurveMigrator public migrator;
    StreamableFeesLockerV2 public locker;
    UniswapV4MigratorHook public hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");

        airlock = new AirlockMock(owner);
        hook = UniswapV4MigratorHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        locker = new StreamableFeesLockerV2(manager, owner);
        migrator = new UniswapV4MulticurveMigrator(address(airlock), manager, hook, locker);
        deployCodeTo("UniswapV4MigratorHook", abi.encode(manager, migrator), address(hook));

        vm.prank(owner);
        locker.approveMigrator(address(migrator));
    }

    function test_constructor() public view {
        assertEq(address(migrator.airlock()), address(airlock));
        assertEq(address(migrator.poolManager()), address(manager));
        assertEq(address(migrator.migratorHook()), address(hook));
        assertEq(address(migrator.locker()), address(locker));
    }

    function test_initialize() public {
        (
            uint24 fee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            Curve[] memory curves
        ) = _prepareInitializeData();

        bytes memory data = abi.encode(fee, tickSpacing, lockDuration, beneficiaries, curves);
        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);

        vm.prank(address(airlock));
        migrator.initialize(asset, numeraire, data);
    }

    function test_initialize_RevertsIfSenderNotAirlock() public {
        (
            uint24 fee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            Curve[] memory curves
        ) = _prepareInitializeData();

        bytes memory data = abi.encode(fee, tickSpacing, lockDuration, beneficiaries, curves);
        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);

        vm.expectRevert(SenderNotAirlock.selector);
        migrator.initialize(asset, numeraire, data);
    }

    function test_migrate() public {
        vm.skip(true);
        (
            uint24 fee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            Curve[] memory curves
        ) = _prepareInitializeData();

        bytes memory data = abi.encode(fee, tickSpacing, lockDuration, beneficiaries, curves);
        address asset = Currency.unwrap(currency0);
        address numeraire = Currency.unwrap(currency1);

        vm.prank(address(airlock));
        migrator.initialize(asset, numeraire, data);

        currency0.transfer(address(migrator), 1e6);
        currency1.transfer(address(migrator), 1e18);

        vm.prank(address(airlock));
        migrator.migrate(Constants.SQRT_PRICE_1_1, Currency.unwrap(currency0), Currency.unwrap(currency1), recipient);
    }

    function _prepareInitializeData()
        internal
        returns (
            uint24 fee,
            int24 tickSpacing,
            uint32 lockDuration,
            BeneficiaryData[] memory beneficiaries,
            Curve[] memory curves
        )
    {
        fee = 3000;
        tickSpacing = 1;
        lockDuration = 7 days;

        beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: makeAddr("Beneficiary1"), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: owner, shares: 0.05e18 });

        curves = new Curve[](2);
        curves[0] = Curve({ tickLower: -100_000, tickUpper: 0, shares: WAD / 2, numPositions: 5 });
        curves[1] = Curve({ tickLower: -50_000, tickUpper: 0, shares: WAD / 2, numPositions: 5 });
    }
}
