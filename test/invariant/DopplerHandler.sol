// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {AddressSet, LibAddressSet} from "./AddressSet.sol";
import {DopplerImplementation} from "test/shared/DopplerImplementation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CustomRouter} from "test/shared/CustomRouter.sol";

contract DopplerHandler is Test {
    using LibAddressSet for AddressSet;

    PoolKey public poolKey;
    DopplerImplementation public hook;
    CustomRouter public router;
    TestERC20 public token0;
    TestERC20 public token1;
    TestERC20 public numeraire;
    TestERC20 public asset;
    bool public isToken0;
    bool public isUsingEth;

    uint256 public ghost_reserve0;
    uint256 public ghost_reserve1;

    mapping(bytes4 => uint256) public calls;
    uint256 public totalCalls;

    AddressSet internal actors;
    address internal currentActor;

    modifier createActor() {
        currentActor = msg.sender;
        actors.add(msg.sender);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors.rand(actorIndexSeed);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier countCall(bytes4 key) {
        calls[key]++;
        totalCalls++;
        _;
    }

    constructor(
        PoolKey memory poolKey_,
        DopplerImplementation hook_,
        CustomRouter router_,
        bool isToken0_,
        bool isUsingEth_
    ) {
        poolKey = poolKey_;
        hook = hook_;
        router = router_;
        isToken0 = isToken0_;
        isUsingEth = isUsingEth_;

        token0 = TestERC20(Currency.unwrap(poolKey.currency0));
        token1 = TestERC20(Currency.unwrap(poolKey.currency1));

        if (isToken0) {
            numeraire = token0;
            asset = token1;
        } else {
            numeraire = token1;
            asset = token0;
        }

        ghost_reserve0 = token0.balanceOf(address(hook));
        ghost_reserve1 = token1.balanceOf(address(hook));
    }

    /// @notice Buys an amount of asset tokens using an exact amount of numeraire tokens
    function buyExactAmountIn(uint256 amount) public createActor countCall(this.buyExactAmountIn.selector) {
        if (isUsingEth) {
            deal(currentActor, amount);
        } else {
            numeraire.mint(currentActor, amount);
            numeraire.approve(address(router), amount);
        }

        uint256 bought = router.buyExactIn{value: isUsingEth ? amount : 0}(amount);
    }
}
