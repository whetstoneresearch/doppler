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

    // Ghost variables are used to mimic the state of the hook contract.
    uint256 public ghost_reserve0;
    uint256 public ghost_reserve1;
    uint256 public ghost_totalTokensSold;
    uint256 public ghost_totalProceeds;

    mapping(bytes4 => uint256) public calls;
    uint256 public totalCalls;

    AddressSet internal actors;
    address internal currentActor;

    mapping(address actor => uint256 balance) public assetBalanceOf;

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
            asset = token0;
            numeraire = token1;
        } else {
            asset = token1;
            numeraire = token0;
        }

        ghost_reserve0 = token0.balanceOf(address(hook));
        ghost_reserve1 = token1.balanceOf(address(hook));
    }

    /// @notice Buys an amount of asset tokens using an exact amount of numeraire tokens
    function buyExactAmountIn(uint256 amountToSpend) public createActor countCall(this.buyExactAmountIn.selector) {
        amountToSpend = 1 ether;

        if (isUsingEth) {
            deal(currentActor, amountToSpend);
        } else {
            numeraire.mint(currentActor, amountToSpend);
            numeraire.approve(address(router), amountToSpend);
        }

        uint256 bought = router.buyExactIn{value: isUsingEth ? amountToSpend : 0}(amountToSpend);
        assetBalanceOf[currentActor] += bought;
        ghost_totalTokensSold += bought;
        ghost_totalProceeds += amountToSpend;

        if (isToken0) {
            ghost_reserve0 -= bought;
            ghost_reserve1 += amountToSpend;
        } else {
            ghost_reserve1 -= bought;
            ghost_reserve0 += amountToSpend;
        }
    }

    function buyExactAmountOut(uint256 assetsToBuy) public createActor countCall(this.buyExactAmountOut.selector) {
        assetsToBuy = 1 ether;
        uint256 amountInRequired = router.computeBuyExactOut(assetsToBuy);

        if (isUsingEth) {
            deal(currentActor, amountInRequired);
        } else {
            numeraire.mint(currentActor, amountInRequired);
            numeraire.approve(address(router), amountInRequired);
        }

        uint256 spent = router.buyExactOut{value: isUsingEth ? amountInRequired : 0}(assetsToBuy);
        assetBalanceOf[currentActor] += assetsToBuy;
        ghost_totalTokensSold += assetsToBuy;
        ghost_totalProceeds += spent;

        if (isToken0) {
            ghost_reserve0 -= assetsToBuy;
            ghost_reserve1 += spent;
        } else {
            ghost_reserve1 -= assetsToBuy;
            ghost_reserve0 += spent;
        }
    }

    function sellExactIn(uint256 seed)
        public
        useActor(uint256(uint160(msg.sender)))
        countCall(this.sellExactIn.selector)
    {
        // If the currentActor is address(0), it means no one has bought any assets yet.
        if (currentActor == address(0) || assetBalanceOf[currentActor] == 0) return;

        uint256 assetsToSell = seed % assetBalanceOf[currentActor] + 1;
        TestERC20(asset).approve(address(router), assetsToSell);
        uint256 received = router.sellExactIn(assetsToSell);

        assetBalanceOf[currentActor] -= assetsToSell;
        ghost_totalTokensSold -= assetsToSell;
        ghost_totalProceeds -= received;

        if (isToken0) {
            ghost_reserve0 += assetsToSell;
            ghost_reserve1 -= received;
        } else {
            ghost_reserve1 += assetsToSell;
            ghost_reserve0 -= received;
        }
    }

    function sellExactOut(uint256 seed)
        public
        useActor(uint256(uint160(msg.sender)))
        countCall(this.sellExactOut.selector)
    {
        // If the currentActor is address(0), it means no one has bought any assets yet.
        if (currentActor == address(0) || assetBalanceOf[currentActor] == 0) return;

        // We compute the maximum amount we can receive from our current balance.
        uint256 maxAmountToReceive = router.computeSellExactOut(assetBalanceOf[currentActor]);

        // Then we compute a random amount from that maximum.
        uint256 amountToReceive = seed % maxAmountToReceive + 1;

        TestERC20(asset).approve(address(router), router.computeSellExactOut(amountToReceive));
        uint256 sold = router.sellExactOut(amountToReceive);

        assetBalanceOf[currentActor] -= sold;
        ghost_totalTokensSold -= sold;
        ghost_totalProceeds -= amountToReceive;

        if (isToken0) {
            ghost_reserve0 += sold;
            ghost_reserve1 -= amountToReceive;
        } else {
            ghost_reserve0 -= amountToReceive;
            ghost_reserve1 += sold;
        }
    }

    function goNextEpoch() public countCall(this.goNextEpoch.selector) {
        vm.warp(block.timestamp + hook.getEpochLength());
    }
}
