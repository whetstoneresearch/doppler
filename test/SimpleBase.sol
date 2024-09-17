pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {DopplerImplementation} from "./DopplerImplementation.sol";

contract SimpleBase is Test, Deployers {
    int24 constant MIN_TICK_SPACING = 1;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;
    uint256 constant INIT_TIMESTAMP = 1000 seconds;

    // Same tokens but just for the sake of avoiding ternary conditions
    TestERC20 internal asset;
    TestERC20 internal token0;

    // Same tokens but just for the sake of avoiding ternary conditions
    TestERC20 internal numeraire;
    TestERC20 internal token1;

    DopplerImplementation internal hook = DopplerImplementation(
        address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG
            )
        )
    );

    function setUp() public virtual {
        manager = new PoolManager();

        asset = new TestERC20(2 ** 128);
        numeraire = new TestERC20(2 ** 128);
        vm.label(address(asset), "Asset");
        vm.label(address(numeraire), "Numeraire");

        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);
        bool isToken0 = asset < numeraire;

        // isToken0 ? startTick > endTick : endTick > startTick
        // In both cases, price(startTick) > price(endTick)
        int24 startTick = isToken0 ? int24(-100_000) : int24(100_000);
        int24 endTick = isToken0 ? int24(-200_000) : int24(200_000);

        uint256 numTokensToSell = 100_000e18;

        deployCodeTo("DopplerImplementation.sol:DopplerImplementation", abi.encode(), address(hook));
    }
}
