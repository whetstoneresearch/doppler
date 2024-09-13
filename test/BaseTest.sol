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
        uint256 gamma,
        bool isToken0
    ) internal {
        uint256 currentTime = block.timestamp;

        // Watches the slots that were read/written to.
        vm.record();
        DopplerImplementation impl0 = new DopplerImplementation({
            _poolManager: poolManager,
            _numTokensToSell: 100_000e18,
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
        TestERC20 token0 = new TestERC20(2 ** 128);
        TestERC20 token1 = new TestERC20(2 ** 128);
        if (token0 > token1) (token0, token1) = (token1, token0);

        vm.warp(INIT_TIMESTAMP);

        Instance memory doppler0;
        doppler0.token0 = token0;
        doppler0.token1 = token1;
        doppler0.hook = targetHookAddress;
        doppler0.tickSpacing = MIN_TICK_SPACING;
        doppler0.deploy({
            vm: vm,
            poolManager: address(manager),
            timeTilStart: 500 seconds,
            duration: 1 days,
            startTick: -100_000,
            endTick: -200_000,
            epochLength: 1 days,
            gamma: 1_000,
            isToken0: true
        });

        __instances__.push(doppler0);
    }
}

error Unauthorized();
