// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {AddressSet, LibAddressSet} from "./AddressSet.sol";
import {DopplerImplementation} from "test/shared/DopplerImplementation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract DopplerHandler is Test {
    using LibAddressSet for AddressSet;

    DopplerImplementation public hook;
    PoolSwapTest public swapRouter;

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

    constructor(DopplerImplementation hook_, PoolSwapTest swapRouter_) {
        hook = hook_;
        swapRouter = swapRouter_;
    }
}
