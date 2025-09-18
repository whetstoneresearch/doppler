// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";

import { WAD } from "src/types/Wad.sol";
import {
    BeneficiaryData,
    UnorderedBeneficiaries,
    InvalidShares,
    InvalidProtocolOwnerShares,
    InvalidTotalShares,
    InvalidProtocolOwnerBeneficiary,
    MIN_PROTOCOL_OWNER_SHARES
} from "src/types/BeneficiaryData.sol";
import { FeesManager, Collect, UpdateBeneficiary } from "src/base/FeesManager.sol";

contract FeesManagerImplementation is FeesManager {
    PoolManagerMock internal poolManager;
    TestERC20 internal token0;
    TestERC20 internal token1;

    constructor(PoolManagerMock poolManager_, TestERC20 token0_, TestERC20 token1_) {
        poolManager = poolManager_;
        token0 = token0_;
        token1 = token1_;
    }

    function _collectFees(
        PoolId
    ) internal override returns (BalanceDelta fees) {
        (uint256 fees0, uint256 fees1) = poolManager.collect();
        fees = toBalanceDelta(int128(uint128(fees0)), int128(uint128(fees1)));
    }

    function storeBeneficiaries(
        BeneficiaryData[] memory beneficiaries,
        address protocolOwner,
        PoolKey memory poolKey
    ) external {
        _storeBeneficiaries(beneficiaries, protocolOwner, MIN_PROTOCOL_OWNER_SHARES, poolKey);
    }
}

contract PoolManagerMock {
    TestERC20 internal token0;
    TestERC20 internal token1;

    constructor(TestERC20 token0_, TestERC20 token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setFees(uint256 amount0, uint256 amount1) external {
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
    }

    function collect() external returns (uint256 amount0, uint256 amount1) {
        amount0 = token0.balanceOf(address(this));
        token0.transfer(msg.sender, amount0);
        amount1 = token1.balanceOf(address(this));
        token1.transfer(msg.sender, amount1);
    }
}

contract FeesManagerTest is Test {
    address internal protocolOwner = address(0xB055);

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

        poolManager = new PoolManagerMock(token0, token1);
        feesManager = new FeesManagerImplementation(poolManager, token0, token1);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            hooks: IHooks(address(0)),
            tickSpacing: 0
        });
        poolId = poolKey.toId();
    }

    function test_storeBeneficiaries_StoresBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });
        feesManager.storeBeneficiaries(beneficiaries, protocolOwner, poolKey);

        assertEq(feesManager.getShares(poolId, address(0xaaa)), 0.95e18);
        assertEq(feesManager.getShares(poolId, protocolOwner), 0.05e18);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });

        vm.expectRevert(InvalidShares.selector);
        feesManager.storeBeneficiaries(beneficiaries, protocolOwner, poolKey);
    }

    function test_storeBeneficiaries_RevertsWhenUnorderedBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xbbb), shares: 0.45e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.505e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });

        vm.expectRevert(UnorderedBeneficiaries.selector);
        feesManager.storeBeneficiaries(beneficiaries, protocolOwner, poolKey);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidProtocolOwnerShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.96e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.04e18 });

        vm.expectRevert(abi.encodeWithSelector(InvalidProtocolOwnerShares.selector, MIN_PROTOCOL_OWNER_SHARES, 0.04e18));
        feesManager.storeBeneficiaries(beneficiaries, protocolOwner, poolKey);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidProtocolOwnerBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0xbbb), shares: 0.5e18 });

        vm.expectRevert(InvalidProtocolOwnerBeneficiary.selector);
        feesManager.storeBeneficiaries(beneficiaries, protocolOwner, poolKey);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidTotalShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.96e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });
        vm.expectRevert(InvalidTotalShares.selector);
        feesManager.storeBeneficiaries(beneficiaries, protocolOwner, poolKey);
    }

    function test_collectFees() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });
        feesManager.storeBeneficiaries(beneficiaries, protocolOwner, poolKey);

        uint256 fees0 = 10e18;
        uint256 fees1 = 20e18;

        poolManager.setFees(fees0, fees1);
        feesManager.collectFees(poolId);

        assertEq(feesManager.getCumulatedFees0(poolId), fees0, "Incorrect cumulated fees0");
        assertEq(feesManager.getCumulatedFees1(poolId), fees1, "Incorrect cumulated fees1");

        for (uint256 i; i != beneficiaries.length; ++i) {
            uint256 expectedFees0 = beneficiaries[i].shares * fees0 / WAD;
            uint256 expectedFees1 = beneficiaries[i].shares * fees1 / WAD;
            address beneficiary = beneficiaries[i].beneficiary;

            vm.prank(beneficiary);
            vm.expectEmit();
            emit Collect(poolId, beneficiary, expectedFees0, expectedFees1);
            feesManager.collectFees(poolId);
            assertEq(token0.balanceOf(beneficiary), expectedFees0, "Wrong collected fees0");
            assertEq(token1.balanceOf(beneficiary), expectedFees1, "Wrong collected fees1");
            assertEq(feesManager.getLastCumulatedFees0(poolId, beneficiary), fees0);
            assertEq(feesManager.getLastCumulatedFees1(poolId, beneficiary), fees1);
        }
    }

    function test_updateBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });
        feesManager.storeBeneficiaries(beneficiaries, protocolOwner, poolKey);

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
