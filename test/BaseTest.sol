pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {Doppler} from "../src/Doppler.sol";
import {DopplerImplementation} from "./DopplerImplementation.sol";

/// @dev Each doppler "instance" has:
/// - An asset token
/// - A proceeds token
/// - A hook contract address w/ hook flags
/// - A tick spacing setting
struct Instance {
    TestERC20 token0;
    TestERC20 token1;
    DopplerImplementation hook;
    int24 tickSpacing;
}

using Debug for Instance global;

/// @dev For getting info about instances and deploying new ones.
library Debug {
    /// @dev derives the pool key given tokens, tick spacing, and hook address
    function key(Instance memory self) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(self.token0)),
            currency1: Currency.wrap(address(self.token1)),
            fee: 0,
            tickSpacing: self.tickSpacing,
            hooks: IHooks(address(self.hook))
        });
    }

    function id(Instance memory self) internal view returns (PoolId) {
        return self.key().toId();
    }

    /// @dev Manually writes a DopplerImplementation contract at the hook address and writes its storage slots.
    function deploy(
        Instance memory self,
        Vm vm,
        address poolManager,
        uint256 timeTilStart,
        uint256 duration,
        int24 startTick,
        int24 endTick,
        uint256 epochLength,
        int24 gamma,
        bool isToken0,
        uint256 numTokensToSell
    ) internal {
        uint256 currentTime = block.timestamp;

        // Watches the slots that were read/written to.
        vm.record();
        DopplerImplementation impl0 = new DopplerImplementation({
            _poolManager: poolManager,
            _poolKey: self.key(),
            _numTokensToSell: numTokensToSell,
            _startingTime: currentTime + timeTilStart,
            _endingTime: currentTime + timeTilStart + duration,
            _startingTick: startTick,
            _endingTick: endTick,
            _epochLength: epochLength,
            _gamma: gamma,
            _isToken0: isToken0, // TODO: Make sure it's consistent with the tick direction
            addressToEtch: self.hook
        });

        // Gets the slots that were written to.
        (, bytes32[] memory writes) = vm.accesses(address(impl0));

        // Sets the bytecode of the desired hook address `doppler0`.
        vm.etch(address(self.hook), address(impl0).code);

        // Copies the written storage slots (i.e. state) from the implementation to the hook.
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(self.hook), slot, vm.load(address(impl0), slot));
            }
        }
    }
}

contract BaseTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MIN_TICK_SPACING = 1;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;
    uint256 constant INIT_TIMESTAMP = 1000 seconds;

    Instance[] public __instances__;

    /// @dev Returns the last instance in the test state.
    function ghost() internal view returns (Instance memory) {
        return __instances__[__instances__.length - 1];
    }

    /// @dev Returns all instances in the test state.
    function ghosts() internal view returns (Instance[] memory) {
        return __instances__;
    }

    DopplerImplementation targetHookAddress = DopplerImplementation(
        address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG))
    );

    function setUp() public virtual {
        manager = new PoolManager();
        TestERC20 asset = new TestERC20(2 ** 128);
        TestERC20 numeraire = new TestERC20(2 ** 128);
        (TestERC20 token0, TestERC20 token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        bool isToken0 = asset < numeraire;

        // isToken0 ? startTick > endTick : endTick > startTick
        // In both cases, price(startTick) > price(endTick)
        int24 startTick = isToken0 ? int24(0) : int24(0);
        int24 endTick = isToken0 ? -172_800 : int24(172_800);

        uint256 numTokensToSell = 100_000e18;

        vm.warp(INIT_TIMESTAMP);

        Instance memory doppler0;
        doppler0.token0 = token0;
        doppler0.token1 = token1;
        doppler0.hook = targetHookAddress;
        // Shouldn't use 1 tickSpacing since we want to test that tickSpacing is respected
        doppler0.tickSpacing = 8;

        doppler0.deploy({
            vm: vm,
            poolManager: address(manager),
            timeTilStart: 500 seconds,
            duration: 1 days,
            startTick: startTick,
            endTick: endTick,
            epochLength: 400 seconds,
            gamma: 800,
            isToken0: isToken0,
            numTokensToSell: numTokensToSell
        });

        // TODO: Consider if there will be a different mechanism used rather than just minting all the tokens straight to the hook
        // Mint the tokens to sell to the hook
        deal(address(asset), address(targetHookAddress), numTokensToSell);

        __instances__.push(doppler0);

        // Initialize each pool at the starting tick
        for (uint256 i; i < __instances__.length; ++i) {
            manager.initialize(
                __instances__[i].key(), TickMath.getSqrtPriceAtTick(__instances__[i].hook.getStartingTick()), ""
            );
        }

        // Deploy swapRouter
        swapRouter = new PoolSwapTest(manager);

        // Deploy modifyLiquidityRouter
        // Note: Only used to validate that liquidity can't be manually modified
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Approve the router to spend tokens on behalf of the test contract
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
    }
}

error Unauthorized();
