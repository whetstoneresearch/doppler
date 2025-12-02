// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { PoolId } from "@v4-core/types/PoolId.sol";
import { Test } from "forge-std/Test.sol";

import {
    BeneficiaryData,
    InvalidProtocolOwnerBeneficiary,
    InvalidProtocolOwnerShares,
    InvalidShares,
    InvalidTotalShares,
    MIN_PROTOCOL_OWNER_SHARES,
    UnorderedBeneficiaries,
    storeBeneficiaries
} from "src/types/BeneficiaryData.sol";

contract BeneficiaryDataTest is Test {
    address public immutable PROTOCOL_OWNER = address(0xB055);
    mapping(PoolId => mapping(address => uint96)) public shares;

    function test_storeBeneficiaries_DoesNotStoreBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = _getValidBeneficiaries();

        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, PROTOCOL_OWNER, MIN_PROTOCOL_OWNER_SHARES, _doNotStoreBeneficiary
        );

        for (uint256 i; i < beneficiaries.length; i++) {
            assertEq(shares[PoolId.wrap(bytes32(0))][beneficiaries[i].beneficiary], 0, "Shares should not be stored");
        }
    }

    function test_storeBeneficiaries_StoresBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = _getValidBeneficiaries();
        PoolId poolId = PoolId.wrap(bytes32(uint256(1)));

        storeBeneficiaries(poolId, beneficiaries, PROTOCOL_OWNER, MIN_PROTOCOL_OWNER_SHARES, _storeBeneficiary);

        for (uint256 i; i < beneficiaries.length; i++) {
            assertEq(shares[poolId][beneficiaries[i].beneficiary], beneficiaries[i].shares, "Shares should be stored");
        }
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_storeBeneficiaries_RevertsIfUnorderedBeneficiaries() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x2), shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0x1), shares: 0.5e18 });

        vm.expectRevert(UnorderedBeneficiaries.selector);
        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, PROTOCOL_OWNER, MIN_PROTOCOL_OWNER_SHARES, _doNotStoreBeneficiary
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_storeBeneficiaries_RevertsIfInvalidShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x1), shares: 0 });

        vm.expectRevert(InvalidShares.selector);
        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, PROTOCOL_OWNER, MIN_PROTOCOL_OWNER_SHARES, _doNotStoreBeneficiary
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_storeBeneficiaries_RevertsIfInvalidProtocolOwnerShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: MIN_PROTOCOL_OWNER_SHARES - 1 });

        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidProtocolOwnerShares.selector, MIN_PROTOCOL_OWNER_SHARES, MIN_PROTOCOL_OWNER_SHARES - 1
            )
        );
        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, PROTOCOL_OWNER, MIN_PROTOCOL_OWNER_SHARES, _doNotStoreBeneficiary
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_storeBeneficiaries_RevertsIfInvalidTotalShares() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x1), shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0x2), shares: 0.6e18 });

        vm.expectRevert(InvalidTotalShares.selector);
        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, PROTOCOL_OWNER, MIN_PROTOCOL_OWNER_SHARES, _doNotStoreBeneficiary
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_storeBeneficiaries_RevertsIfProtocolOwnerBeneficiaryNotFound() public {
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](1);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x1), shares: 1e18 });

        vm.expectRevert(InvalidProtocolOwnerBeneficiary.selector);
        storeBeneficiaries(
            PoolId.wrap(bytes32(0)), beneficiaries, PROTOCOL_OWNER, MIN_PROTOCOL_OWNER_SHARES, _doNotStoreBeneficiary
        );
    }

    function _storeBeneficiary(PoolId poolId, BeneficiaryData memory beneficiary) internal {
        shares[poolId][beneficiary.beneficiary] = beneficiary.shares;
    }

    function _doNotStoreBeneficiary(PoolId, BeneficiaryData memory) internal { }

    function _getValidBeneficiaries() internal view returns (BeneficiaryData[] memory beneficiaries) {
        beneficiaries = new BeneficiaryData[](4);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x1), shares: 0.5e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0x2), shares: 0.3e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: address(0x3), shares: 0.15e18 });
        beneficiaries[3] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: MIN_PROTOCOL_OWNER_SHARES });
    }
}
