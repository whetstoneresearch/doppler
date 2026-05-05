// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC721 } from "@solmate/tokens/ERC721.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { StreamableFeesLocker } from "src/StreamableFeesLocker.sol";
import { UniswapV4MigratorSplit } from "src/migrators/UniswapV4MigratorSplit.sol";
import { UniswapV4MigratorSplitHook } from "src/migrators/UniswapV4MigratorSplitHook.sol";
import {
    BeneficiaryData,
    InvalidProtocolOwnerBeneficiary,
    InvalidProtocolOwnerShares,
    InvalidShares,
    InvalidTotalShares,
    MIN_PROTOCOL_OWNER_SHARES,
    UnorderedBeneficiaries
} from "src/types/BeneficiaryData.sol";
// We don't use the `PositionDescriptor` contract explictly here but importing it ensures it gets compiled
import { PosmTestSetup } from "@v4-periphery-test/shared/PosmTestSetup.sol";
import { PositionDescriptor } from "@v4-periphery/PositionDescriptor.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";

contract MockAirlock {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

contract UniswapV4MigratorTest is PosmTestSetup {
    MockAirlock public airlock;
    address public protocolOwner = address(0xb055);

    UniswapV4MigratorSplit public migrator;
    UniswapV4MigratorSplitHook public migratorHook;
    StreamableFeesLocker public locker;
    TopUpDistributor public topUpDistributor;

    address public asset;
    address public numeraire;
    address public token0;
    address public token1;

    uint256 constant TOKEN_ID = 1;
    address constant BENEFICIARY_1 = address(0x1111);
    address constant BENEFICIARY_2 = address(0x2222);
    address constant BENEFICIARY_3 = address(0x3333);
    address constant RECIPIENT = address(0x4444);
    address constant PROCEEDS_RECIPIENT = address(0x5555);

    int24 constant TICK_SPACING = 8;
    uint24 constant FEE = 3000;
    uint32 constant LOCK_DURATION = 30 days;
    uint256 constant PROCEEDS_SHARE = 0.0; // 10%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployPosm(manager);

        airlock = new MockAirlock(protocolOwner);
        migratorHook = UniswapV4MigratorSplitHook(
            address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                ) ^ (0x4444 << 144)
            )
        );
        locker = new StreamableFeesLocker(lpm, address(this));
        topUpDistributor = new TopUpDistributor(address(airlock));
        migrator = new UniswapV4MigratorSplit(
            address(airlock),
            IPoolManager(manager),
            PositionManager(payable(address(lpm))),
            StreamableFeesLocker(locker),
            IHooks(migratorHook),
            topUpDistributor
        );
        locker.approveMigrator(address(migrator));
        deployCodeTo("UniswapV4MigratorSplitHook", abi.encode(manager, migrator), address(migratorHook));

        vm.prank(protocolOwner);
        topUpDistributor.setPullUp(address(migrator), true);
    }

    function _setUpTokens() internal {
        asset = address(new TestERC20(0));
        numeraire = address(new TestERC20(0));
        token0 = address(asset);
        token1 = address(numeraire);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        vm.label(token0, "Token0");
        vm.label(token1, "Token1");
    }

    function test_initialize_StoresPoolKey() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );

        (PoolKey memory poolKey, uint256 lockDuration) = migrator.getAssetData(token0, token1);
        assertEq(Currency.unwrap(poolKey.currency0), token0);
        assertEq(Currency.unwrap(poolKey.currency1), token1);
        assertEq(poolKey.fee, FEE);
        assertEq(poolKey.tickSpacing, TICK_SPACING);
        assertEq(address(poolKey.hooks), address(migratorHook));
        assertEq(lockDuration, LOCK_DURATION);
    }

    /// forge-config: default.fuzz.runs = 512
    function test_migrate(bool isUsingETH, bool hasRecipient, uint64 balance0, uint64 balance1) public {
        vm.assume((balance0 > 1e18 && balance1 < 1e18) || (balance0 < 1e18 && balance1 > 1e18));
        _setUpTokens();

        // TODO: Fuzz the sqrtPrice
        uint160 sqrtPriceX96 = 6_786_529_797_232_128_452_535_845;

        if (isUsingETH) {
            asset = numeraire;
            token1 = asset;
            token0 = address(0);
            numeraire = address(0);
        }

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            asset, numeraire, abi.encode(FEE, 1, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );

        isUsingETH ? deal(address(migrator), balance0) : TestERC20(token0).mint(address(migrator), balance0);
        TestERC20(token1).mint(address(migrator), balance1);

        address recipient = hasRecipient ? RECIPIENT : address(0xdead);

        vm.prank(address(airlock));
        migrator.migrate(sqrtPriceX96, token0, token1, recipient);

        if (recipient != address(0xdead)) {
            assertGe(ERC721(address(lpm)).balanceOf(address(recipient)), 1, "Wrong recipient balance");
            assertGe(ERC721(address(lpm)).balanceOf(address(locker)), 1, "Wrong locker balance with recipient");
        } else {
            assertGe(ERC721(address(lpm)).balanceOf(address(locker)), 1, "Wrong locker balance without recipient");
        }

        if (isUsingETH) {
            assertEq(address(migrator).balance, 0, "Migrator should have no ETH left");
        } else {
            assertEq(TestERC20(token0).balanceOf(address(migrator)), 0, "Migrator should have no token0 left");
        }
        assertEq(TestERC20(token1).balanceOf(address(migrator)), 0, "Migrator should have no token1 left");
    }

    function test_initialize_RevertZeroAddressBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(UnorderedBeneficiaries.selector));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_RevertZeroShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidShares.selector));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_RevertIncorrectTotalShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.35e18 });
        beneficiaries[2] = BeneficiaryData({
            beneficiary: airlock.owner(),
            shares: 0.05e18 // Total is 0.9e18, not 1e18
        });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidTotalShares.selector));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_IncludesDopplerOwnerBeneficiary() public {
        // Set up beneficiaries without protocol owner
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.5e18 }); // 50%
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.4e18 }); // 40%
        beneficiaries[2] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.1e18 }); // 10%

        vm.prank(address(airlock));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_RevertInvalidProtocolOwnerShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.951e18 }); // 95.1%
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.049e18 }); // 4.9%

        vm.prank(address(airlock));
        vm.expectRevert(
            abi.encodeWithSelector(InvalidProtocolOwnerShares.selector, MIN_PROTOCOL_OWNER_SHARES, 0.049e18)
        );
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }

    function test_initialize_RevertProtocolOwnerNotFound() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.4e18 }); // 40%
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.6e18 }); // 60%

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerBeneficiary.selector));
        migrator.initialize(
            address(asset),
            address(numeraire),
            abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries, PROCEEDS_RECIPIENT, PROCEEDS_SHARE)
        );
    }
}
