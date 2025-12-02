// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { Collect, FeesManager, Release, UpdateBeneficiary } from "src/base/FeesManager.sol";
import {
    BeneficiaryData,
    InvalidProtocolOwnerBeneficiary,
    InvalidProtocolOwnerShares,
    InvalidShares,
    InvalidTotalShares,
    MIN_PROTOCOL_OWNER_SHARES,
    UnorderedBeneficiaries
} from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract FeesManagerImplementation is FeesManager {
    address internal immutable PROTOCOL_OWNER;
    PoolManagerMock internal poolManager;

    constructor(address PROTOCOL_OWNER_, PoolManagerMock poolManager_) {
        PROTOCOL_OWNER = PROTOCOL_OWNER_;
        poolManager = poolManager_;
    }

    function storeBeneficiaries(PoolKey memory poolKey, BeneficiaryData[] memory beneficiaries) external {
        _storeBeneficiaries(poolKey, beneficiaries, PROTOCOL_OWNER, MIN_PROTOCOL_OWNER_SHARES);
    }

    function _collectFees(PoolId poolId) internal override returns (BalanceDelta fees) {
        (uint256 fees0, uint256 fees1) = poolManager.collect(getPoolKey[poolId]);
        fees = toBalanceDelta(int128(uint128(fees0)), int128(uint128(fees1)));
    }
}

contract PoolManagerMock {
    function setFees(PoolKey memory poolKey, uint256 amount0, uint256 amount1) external {
        TestERC20(Currency.unwrap(poolKey.currency0)).mint(address(this), amount0);
        TestERC20(Currency.unwrap(poolKey.currency1)).mint(address(this), amount1);
    }

    function collect(PoolKey memory poolKey) external returns (uint256 amount0, uint256 amount1) {
        amount0 = poolKey.currency0.balanceOf(address(this));
        poolKey.currency0.transfer(msg.sender, amount0);
        amount1 = poolKey.currency1.balanceOf(address(this));
        poolKey.currency1.transfer(msg.sender, amount1);
    }
}

contract FeesManagerTest is Test {
    address internal constant PROTOCOL_OWNER = address(0xB055);

    TestERC20 internal token0;
    TestERC20 internal token1;
    PoolManagerMock internal poolManager;
    FeesManagerImplementation internal feesManager;

    PoolId internal poolId;
    PoolKey internal poolKey;

    function setUp() public {
        token0 = new TestERC20(0);
        token1 = new TestERC20(0);

        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        poolManager = new PoolManagerMock();
        feesManager = new FeesManagerImplementation(PROTOCOL_OWNER, poolManager);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            hooks: IHooks(address(0)),
            tickSpacing: 0
        });
        poolId = poolKey.toId();
    }

    /* ---------------------------------------------------------------------------------- */
    /*                                storeBeneficiaries()                                */
    /* ---------------------------------------------------------------------------------- */

    function test_storeBeneficiaries_StoresBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.05e18 });
        feesManager.storeBeneficiaries(poolKey, beneficiaries);

        assertEq(feesManager.getShares(poolId, address(0xaaa)), 0.95e18);
        assertEq(feesManager.getShares(poolId, PROTOCOL_OWNER), 0.05e18);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.05e18 });

        vm.expectRevert(InvalidShares.selector);
        feesManager.storeBeneficiaries(poolKey, beneficiaries);
    }

    function test_storeBeneficiaries_RevertsWhenUnorderedBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xbbb), shares: 0.45e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.505e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.05e18 });

        vm.expectRevert(UnorderedBeneficiaries.selector);
        feesManager.storeBeneficiaries(poolKey, beneficiaries);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidProtocolOwnerShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.96e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.04e18 });

        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerShares.selector, MIN_PROTOCOL_OWNER_SHARES, 0.04e18));
        feesManager.storeBeneficiaries(poolKey, beneficiaries);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidProtocolOwnerBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0xbbb), shares: 0.5e18 });

        vm.expectRevert(InvalidProtocolOwnerBeneficiary.selector);
        feesManager.storeBeneficiaries(poolKey, beneficiaries);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidTotalShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.96e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.05e18 });
        vm.expectRevert(InvalidTotalShares.selector);
        feesManager.storeBeneficiaries(poolKey, beneficiaries);
    }

    /* --------------------------------------------------------------------------- */
    /*                                collectFees()                                */
    /* --------------------------------------------------------------------------- */

    function test_collectFees_CollectPoolFees(uint256 fees0, uint256 fees1) public {
        vm.assume(fees0 < type(uint48).max && fees1 < type(uint48).max);

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.05e18 });
        feesManager.storeBeneficiaries(poolKey, beneficiaries);

        poolManager.setFees(poolKey, fees0, fees1);

        vm.expectEmit();
        emit Collect(poolId, fees0, fees1);
        feesManager.collectFees(poolId);

        assertEq(feesManager.getCumulatedFees0(poolId), fees0, "Incorrect cumulated fees0");
        assertEq(feesManager.getCumulatedFees1(poolId), fees1, "Incorrect cumulated fees1");

        for (uint256 i; i != beneficiaries.length; ++i) {
            uint256 expectedFees0 = beneficiaries[i].shares * fees0 / WAD;
            uint256 expectedFees1 = beneficiaries[i].shares * fees1 / WAD;
            address beneficiary = beneficiaries[i].beneficiary;

            vm.prank(beneficiary);
            vm.expectEmit();
            emit Release(poolId, beneficiary, expectedFees0, expectedFees1);
            feesManager.collectFees(poolId);
            assertEq(token0.balanceOf(beneficiary), expectedFees0, "Wrong collected fees0");
            assertEq(token1.balanceOf(beneficiary), expectedFees1, "Wrong collected fees1");
            assertEq(feesManager.getLastCumulatedFees0(poolId, beneficiary), fees0);
            assertEq(feesManager.getLastCumulatedFees1(poolId, beneficiary), fees1);
        }
    }

    function test_collectFees_ReleasesIfBeneficiary(uint256 fees0, uint256 fees1) public {
        vm.assume(fees0 < type(uint48).max && fees1 < type(uint48).max);

        address beneficiary0 = address(0xaaa);
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: beneficiary0, shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.05e18 });
        feesManager.storeBeneficiaries(poolKey, beneficiaries);

        poolManager.setFees(poolKey, fees0, fees1);

        uint256 expectedFees0 = fees0 * 95 / 100;
        uint256 expectedFees1 = fees1 * 95 / 100;

        vm.expectEmit();
        emit Release(poolId, beneficiary0, expectedFees0, expectedFees1);
        vm.prank(beneficiary0);
        feesManager.collectFees(poolId);

        assertEq(token0.balanceOf(beneficiary0), expectedFees0, "Wrong collected fees0");
        assertEq(token1.balanceOf(beneficiary0), expectedFees1, "Wrong collected fees1");
        assertEq(feesManager.getLastCumulatedFees0(poolId, beneficiary0), fees0);
        assertEq(feesManager.getLastCumulatedFees1(poolId, beneficiary0), fees1);
    }

    /* --------------------------------------------------------------------------------- */
    /*                                updateBeneficiary()                                */
    /* --------------------------------------------------------------------------------- */

    function test_updateBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.05e18 });
        feesManager.storeBeneficiaries(poolKey, beneficiaries);

        vm.expectEmit();
        emit UpdateBeneficiary(poolId, address(0xaaa), address(0xbbb));
        vm.prank(address(0xaaa));
        feesManager.updateBeneficiary(poolId, address(0xbbb));
        assertEq(feesManager.getShares(poolId, address(0xaaa)), 0, "Incorrect previous beneficiary shares");
        assertEq(feesManager.getShares(poolId, address(0xbbb)), 0.95e18, "Incorrect new beneficiary shares");
        uint256 getCumulatedFees0 = feesManager.getCumulatedFees0(poolId);
        uint256 getCumulatedFees1 = feesManager.getCumulatedFees1(poolId);

        assertEq(feesManager.getLastCumulatedFees0(poolId, address(0xbbb)), getCumulatedFees0);
        assertEq(feesManager.getLastCumulatedFees1(poolId, address(0xbbb)), getCumulatedFees1);
        assertEq(feesManager.getLastCumulatedFees0(poolId, address(0xaaa)), getCumulatedFees0);
        assertEq(feesManager.getLastCumulatedFees1(poolId, address(0xaaa)), getCumulatedFees1);
    }
}
