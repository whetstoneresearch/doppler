// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";

import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import {
    FeesManager,
    UnorderedBeneficiaries,
    InvalidShares,
    InvalidProtocolOwnerShares,
    InvalidTotalShares,
    InvalidProtocolOwnerBeneficiary
} from "src/base/FeesManager.sol";

contract FeesManagerImplementation is FeesManager {
    function _collectFees(
        PoolId poolId
    ) internal pure override returns (BalanceDelta fees) {
        return BalanceDelta.wrap(0);
    }

    function storeBeneficiaries(
        PoolId poolId,
        address protocolOwner,
        BeneficiaryData[] memory beneficiaries
    ) external {
        _storeBeneficiaries(poolId, protocolOwner, beneficiaries);
    }
}

contract FeesManagerTest is Test {
    TestERC20 internal token0;
    TestERC20 internal token1;
    FeesManagerImplementation internal feesManager;
    PoolId internal poolId;
    PoolKey internal poolKey;
    address internal protocolOwner = address(0xB055);

    function setUp() public {
        token0 = new TestERC20(0);
        token1 = new TestERC20(0);

        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);

        feesManager = new FeesManagerImplementation();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            hooks: IHooks(address(0)),
            tickSpacing: 0
        });
        poolId = poolKey.toId();
    }

    function test_storeBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });
        feesManager.storeBeneficiaries(poolId, protocolOwner, beneficiaries);

        assertEq(feesManager.getShares(poolId, address(0xaaa)), 0.95e18);
        assertEq(feesManager.getShares(poolId, protocolOwner), 0.05e18);
    }

    function test_storeBeneficiaries_RevertsWhenUnorderedBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xbbb), shares: 0.45e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.505e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });

        vm.expectRevert(UnorderedBeneficiaries.selector);
        feesManager.storeBeneficiaries(poolId, protocolOwner, beneficiaries);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidProtocolOwnerShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.96e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.04e18 });

        vm.expectRevert(InvalidProtocolOwnerShares.selector);
        feesManager.storeBeneficiaries(poolId, protocolOwner, beneficiaries);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidProtocolOwnerBeneficiary() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0xbbb), shares: 0.5e18 });

        vm.expectRevert(InvalidProtocolOwnerBeneficiary.selector);
        feesManager.storeBeneficiaries(poolId, protocolOwner, beneficiaries);
    }

    function test_storeBeneficiaries_RevertsWhenInvalidTotalShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.96e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: protocolOwner, shares: 0.05e18 });
        vm.expectRevert(InvalidTotalShares.selector);
        feesManager.storeBeneficiaries(poolId, protocolOwner, beneficiaries);
    }

    function test_collectFees() public { }

    function test_updateBeneficiary() public { }
}
