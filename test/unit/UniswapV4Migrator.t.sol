// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { IExtsload } from "@v4-core/interfaces/IExtsload.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { UniswapV4Migrator } from "src/UniswapV4Migrator.sol";
import { StreamableFeesLocker, BeneficiaryData } from "src/StreamableFeesLocker.sol";

contract UniswapV4MigratorTest is Test {
    using PoolIdLibrary for PoolKey;

    address public airlock = makeAddr("airlock");
    address public poolManager = makeAddr("poolManager");
    address public positionManager = makeAddr("positionManager");
    address public locker = makeAddr("locker");

    UniswapV4Migrator public migrator;
    TestERC20 public asset;
    TestERC20 public numeraire;

    function setUp() public {
        asset = new TestERC20(1e27);
        numeraire = new TestERC20(1e27);
        migrator = new UniswapV4Migrator(airlock, poolManager, payable(positionManager), StreamableFeesLocker(locker));
    }

    /// @dev We're defining `extsload` here again (from `IExtslod`) because solc is not able to
    /// determine the right function selector to use when importing the interface
    function extsload(
        bytes32 slot
    ) external view returns (bytes32 value) { }

    function test_initialize_StoresPoolKey() public {
        int24 tickSpacing = 8;
        uint24 fee = 3000;

        address token0 = address(asset);
        address token1 = address(numeraire);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x123), shares: uint64(1 ether) });

        vm.prank(airlock);
        migrator.initialize(address(asset), address(numeraire), abi.encode(fee, tickSpacing, beneficiaries));

        (PoolKey memory poolKey) = migrator.getAssetData(token0, token1);
        assertEq(Currency.unwrap(poolKey.currency0), token0);
        assertEq(Currency.unwrap(poolKey.currency1), token1);
        assertEq(poolKey.fee, fee);
        assertEq(poolKey.tickSpacing, tickSpacing);
        assertEq(address(poolKey.hooks), address(0));
    }

    // TODO: Update this test
    function test_migrate_MigratesToUniV4() public {
        vm.skip(true);
        int24 tickSpacing = 8;
        uint24 fee = 3000;

        address token0 = address(asset);
        address token1 = address(numeraire);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x123), shares: uint64(1 ether) });

        vm.prank(airlock);
        migrator.initialize(address(asset), address(numeraire), abi.encode(fee, tickSpacing, beneficiaries));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            hooks: IHooks(address(0)),
            fee: fee,
            tickSpacing: tickSpacing
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
        int24 tickSpacing = 8;
        uint24 fee = 3000;

        address token0 = address(asset);
        address token1 = address(numeraire);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        // Initialize with empty beneficiary data for no-op governance
        vm.prank(airlock);
        migrator.initialize(address(asset), address(numeraire), abi.encode(fee, tickSpacing, new BeneficiaryData[](0)));

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
            fee: fee,
            tickSpacing: tickSpacing
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
        vm.prank(airlock);
        uint256 liquidity = migrator.migrate(TickMath.MIN_SQRT_PRICE, token0, token1, recipient);

        // Verify the migrator recognizes this as no-op governance
        assertTrue(liquidity > 0, "Liquidity should be greater than 0");

        // In a real test, we would verify:
        // 1. Only one NFT position was created (not two)
        // 2. All liquidity went to the locker
        // 3. No position was sent to the timelock
    }
}
