// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {AddressSet, LibAddressSet} from "./AddressSet.sol";
import {DopplerImplementation} from "test/shared/DopplerImplementation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Quoter, IQuoter} from "v4-periphery/src/lens/Quoter.sol";

contract DopplerHandler is Test {
    using LibAddressSet for AddressSet;

    PoolKey public poolKey;
    DopplerImplementation public hook;
    PoolSwapTest public swapRouter;
    Quoter public quoter;
    TestERC20 public token0;
    TestERC20 public token1;

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

    constructor(PoolKey memory poolKey_, DopplerImplementation hook_, PoolSwapTest swapRouter_, Quoter quoter_) {
        poolKey = poolKey_;
        hook = hook_;
        swapRouter = swapRouter_;
        quoter = quoter_;

        token0 = TestERC20(Currency.unwrap(poolKey.currency0));
        token1 = TestERC20(Currency.unwrap(poolKey.currency1));

        ghost_reserve0 = token0.balanceOf(address(hook));
        ghost_reserve1 = token1.balanceOf(address(hook));
    }

    function buyExactAmount(uint256 amount) public createActor countCall(this.buyExactAmount.selector) {}
}
