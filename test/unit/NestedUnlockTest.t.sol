// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@v4-core/types/BeforeSwapDelta.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { PoolModifyLiquidityTest } from "@v4-core/test/PoolModifyLiquidityTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { HookMiner } from "@v4-periphery/utils/HookMiner.sol";

/// @notice Hook that tries to call unlock() from afterAddLiquidity
contract NestedUnlockHook is BaseHook {
    bytes public capturedRevertData;
    bool public didRevert;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        // Try to call unlock() while already unlocked
        try poolManager.unlock("nested") returns (bytes memory) {
            // Should not reach here
        } catch (bytes memory revertData) {
            capturedRevertData = revertData;
            didRevert = true;
        }

        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // Skip hook address validation for testing
    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice Deployer for mining valid hook addresses
contract NestedUnlockHookDeployer {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function deploy(bytes32 salt) external returns (NestedUnlockHook) {
        return new NestedUnlockHook{salt: salt}(poolManager);
    }
}

contract NestedUnlockTest is Test, Deployers {
    NestedUnlockHook hook;
    NestedUnlockHookDeployer hookDeployer;
    PoolKey poolKey;

    address constant TOKEN_A = address(0x1111);
    address constant TOKEN_B = address(0x2222);

    function getHookFlags() internal pure returns (uint160) {
        return uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG);
    }

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy hook deployer
        hookDeployer = new NestedUnlockHookDeployer(manager);

        // Mine valid hook address
        (, bytes32 salt) = HookMiner.find(
            address(hookDeployer),
            getHookFlags(),
            type(NestedUnlockHook).creationCode,
            abi.encode(manager)
        );

        // Deploy hook at valid address
        hook = hookDeployer.deploy(salt);

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        (address token0, address token1) = TOKEN_A < TOKEN_B ? (TOKEN_A, TOKEN_B) : (TOKEN_B, TOKEN_A);

        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool
        manager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));

        // Deploy router
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Approve tokens
        TestERC20(token0).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(token1).approve(address(modifyLiquidityRouter), type(uint256).max);
    }

    function test_captureNestedUnlockError() public {
        // Add liquidity - this will trigger afterAddLiquidity which tries to call unlock()
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ""
        );

        // Check what we captured
        assertTrue(hook.didRevert(), "Should have reverted");

        bytes memory revertData = hook.capturedRevertData();
        console2.log("Revert data length:", revertData.length);
        console2.logBytes(revertData);

        if (revertData.length >= 4) {
            bytes4 selector = bytes4(revertData);
            console2.log("Selector:");
            console2.logBytes4(selector);

            // Check if it's AlreadyUnlocked
            bytes4 expectedSelector = IPoolManager.AlreadyUnlocked.selector;
            console2.log("Expected AlreadyUnlocked selector:");
            console2.logBytes4(expectedSelector);

            assertEq(selector, expectedSelector, "Should be AlreadyUnlocked error");
        } else if (revertData.length == 0) {
            console2.log("Empty revert (no data)");
        }
    }
}
