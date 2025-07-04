// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IExtsload } from "@v4-core/interfaces/IExtsload.sol";
import { PositionManager } from "@v4-periphery/PositionManager.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { UniswapV4Migrator, AssetData } from "src/UniswapV4Migrator.sol";
import { StreamableFeesLocker, BeneficiaryData } from "src/StreamableFeesLocker.sol";
import { UniswapV4MigratorHook } from "src/UniswapV4MigratorHook.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";

error TickOutOfRange();
error ZeroLiquidity();
error UnorderedBeneficiaries();
error InvalidShares();
error InvalidTotalShares();
error InvalidLength();
error InvalidProtocolOwnerShares();
error InvalidProtocolOwnerBeneficiary();

contract MockAirlock {
    address public owner;

    constructor(
        address _owner
    ) {
        owner = _owner;
    }
}

contract UniswapV4MigratorTest is Test {
    using PoolIdLibrary for PoolKey;

    MockAirlock public airlock;
    address public poolManager = makeAddr("poolManager");
    address payable public positionManager = payable(makeAddr("positionManager"));
    address payable public locker = payable(makeAddr("locker"));
    address public protocolOwner = makeAddr("protocolOwner");

    UniswapV4Migrator public migrator;
    UniswapV4MigratorHook public migratorHook;
    TestERC20 public asset;
    TestERC20 public numeraire;
    address public token0;
    address public token1;

    uint256 constant TOKEN_ID = 1;
    address constant BENEFICIARY_1 = address(0x1111);
    address constant BENEFICIARY_2 = address(0x2222);
    address constant BENEFICIARY_3 = address(0x3333);
    address constant RECIPIENT = address(0x4444);

    int24 constant TICK_SPACING = 8;
    uint24 constant FEE = 3000;
    uint32 constant LOCK_DURATION = 30 days;

    function setUp() public {
        airlock = new MockAirlock(protocolOwner);
        asset = new TestERC20(1e27);
        numeraire = new TestERC20(1e27);
        migratorHook = UniswapV4MigratorHook(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG) ^ (0x4444 << 144)));
        migrator = new UniswapV4Migrator(
            address(airlock),
            IPoolManager(poolManager),
            PositionManager(positionManager),
            StreamableFeesLocker(locker),
            IHooks(migratorHook)
        );
        deployCodeTo("UniswapV4MigratorHook", abi.encode(poolManager, migrator), address(migratorHook));

        token0 = address(asset);
        token1 = address(numeraire);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
    }

    /// @dev We're defining `extsload` here again (from `IExtslod`) because solc is not able to
    /// determine the right function selector to use when importing the interface
    function extsload(
        bytes32 slot
    ) external view returns (bytes32 value) { }

    function test_initialize_StoresPoolKey() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
        );

        (PoolKey memory poolKey, uint256 lockDuration) = migrator.getAssetData(token0, token1);
        assertEq(Currency.unwrap(poolKey.currency0), token0);
        assertEq(Currency.unwrap(poolKey.currency1), token1);
        assertEq(poolKey.fee, FEE);
        assertEq(poolKey.tickSpacing, TICK_SPACING);
        assertEq(address(poolKey.hooks), address(migratorHook));
        assertEq(lockDuration, LOCK_DURATION);
    }

    // TODO: Update this test
    function test_migrate_MigratesToUniV4() public {
        vm.skip(true);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });

        vm.prank(address(airlock));
        migrator.initialize(
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            hooks: IHooks(address(0)),
            fee: FEE,
            tickSpacing: TICK_SPACING
        });

        bytes memory getSlot0Call = abi.encodeWithSelector(this.extsload.selector, poolKey.toId());
        vm.mockCall(poolManager, getSlot0Call, abi.encode(uint160(0), int24(0), uint24(0), uint24(0)));
        vm.expectCall(poolManager, getSlot0Call);

        bytes memory initializeCall =
            abi.encodeWithSelector(IPoolManager.initialize.selector, poolKey, TickMath.MIN_SQRT_PRICE);
        vm.expectCall(poolManager, initializeCall);

        // TODO: Encoding the call here is pretty tedious since we have to use the PositionManager
        vm.mockCall(poolManager, initializeCall, new bytes(0));
    }

    // TODO: Update this test
    function test_migrate_NoOpGovernance_SendsAllToLocker() public {
        vm.skip(true);

        // Initialize with empty beneficiary data for no-op governance
        vm.prank(address(airlock));
        migrator.initialize(
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, new BeneficiaryData[](0))
        );

        // Setup balances
        uint256 amount0 = 1000e18;
        uint256 amount1 = 2000e18;
        TestERC20(token0).mint(address(migrator), amount0);
        TestERC20(token1).mint(address(migrator), amount1);

        // Use DEAD_ADDRESS as recipient (simulating no-op governance)
        address recipient = migrator.DEAD_ADDRESS();

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            hooks: IHooks(address(0)),
            fee: FEE,
            tickSpacing: TICK_SPACING
        });

        // Mock pool manager calls
        bytes memory getSlot0Call = abi.encodeWithSelector(this.extsload.selector, poolKey.toId());
        vm.mockCall(poolManager, getSlot0Call, abi.encode(uint160(0), int24(0), uint24(0), uint24(0)));

        bytes memory initializeCall =
            abi.encodeWithSelector(IPoolManager.initialize.selector, poolKey, TickMath.MIN_SQRT_PRICE);
        vm.mockCall(poolManager, initializeCall, new bytes(0));

        // Mock position manager calls
        // For no-op governance, we expect only ONE MINT_POSITION action
        vm.mockCall(positionManager, bytes(""), new bytes(0));

        // Call migrate with DEAD_ADDRESS as recipient
        vm.prank(address(airlock));
        uint256 liquidity = migrator.migrate(TickMath.MIN_SQRT_PRICE, token0, token1, recipient);

        // Verify the migrator recognizes this as no-op governance
        assertTrue(liquidity > 0, "Liquidity should be greater than 0");

        // In a real test, we would verify:
        // 1. Only one NFT position was created (not two)
        // 2. All liquidity went to the locker
        // 3. No position was sent to the timelock
    }

    function test_initialize_RevertZeroAddressBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(UnorderedBeneficiaries.selector));
        migrator.initialize(
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
        );
    }

    function test_initialize_RevertNoBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](0);
        bytes memory positionData = abi.encode(RECIPIENT, beneficiaries);

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidLength.selector));
        migrator.initialize(
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
        );
    }

    function test_initialize_RevertZeroShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0 });

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidShares.selector));
        migrator.initialize(
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
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
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
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
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
        );
    }

    function test_initialize_RevertInvalidProtocolOwnerShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.951e18 }); // 95.1%
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.049e18 }); // 4.9%

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerShares.selector));
        migrator.initialize(
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
        );
    }

    function test_initialize_RevertProtocolOwnerNotFound() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BENEFICIARY_1, shares: 0.4e18 }); // 40%
        beneficiaries[1] = BeneficiaryData({ beneficiary: BENEFICIARY_2, shares: 0.6e18 }); // 60%

        vm.prank(address(airlock));
        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerBeneficiary.selector));
        migrator.initialize(
            address(asset), address(numeraire), abi.encode(FEE, TICK_SPACING, LOCK_DURATION, beneficiaries)
        );
    }
}
