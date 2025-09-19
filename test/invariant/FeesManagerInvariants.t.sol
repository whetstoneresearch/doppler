// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";

import { WAD } from "src/types/Wad.sol";
import { BeneficiaryData, MIN_PROTOCOL_OWNER_SHARES } from "src/types/BeneficiaryData.sol";
import { FeesManagerImplementation, PoolManagerMock } from "test/unit/FeesManager.t.sol";

address constant PROTOCOL_OWNER = address(0xB16B055);

contract FeesManagerHandler is Test {
    FeesManagerImplementation public implementation;
    PoolManagerMock public poolManager;

    mapping(address beneficiary => uint256 claimed0) public ghost_claimed0;
    mapping(address beneficiary => uint256 claimed1) public ghost_claimed1;

    mapping(address beneficiary => uint256 owed0) public ghost_owed0;
    mapping(address beneficiary => uint256 owed1) public ghost_owed1;

    mapping(address beneficiary => uint256 shares) public ghost_shares;

    uint256 public ghost_totalOwed0;
    uint256 public ghost_totalOwed1;

    uint256 public ghost_totalFees0;
    uint256 public ghost_totalFees1;

    uint256 public ghost_totalClaimed0;
    uint256 public ghost_totalClaimed1;

    PoolKey public poolKey;
    PoolId public poolId;
    BeneficiaryData[] public beneficiaries;

    constructor(
        FeesManagerImplementation implementation_,
        PoolManagerMock poolManager_,
        PoolKey memory poolKey_,
        BeneficiaryData[] memory beneficiaries_
    ) {
        implementation = implementation_;
        poolManager = poolManager_;
        poolKey = poolKey_;
        poolId = poolKey_.toId();

        for (uint256 i; i != beneficiaries_.length; ++i) {
            beneficiaries.push(beneficiaries_[i]);
            ghost_shares[beneficiaries_[i].beneficiary] = beneficiaries_[i].shares;
            implementation.storeBeneficiaries(beneficiaries_, PROTOCOL_OWNER, poolKey);
        }
    }

    function collectFees(uint256 fees0, uint256 fees1) public {
        fees0 = bound(fees0, 0, type(uint48).max);
        fees1 = bound(fees1, 0, type(uint48).max);
        poolManager.setFees(fees0, fees1);

        // We assume all fees are owed at the beginning, then we'll adjust if the sender is a beneficiary
        ghost_totalOwed0 += fees0;
        ghost_totalOwed1 += fees1;

        // Dumbest and most straightforward way of tracking fees to compare against the implementation
        for (uint256 i; i != beneficiaries.length; ++i) {
            BeneficiaryData memory beneficiaryData = beneficiaries[i];
            ghost_owed0[beneficiaryData.beneficiary] += beneficiaryData.shares * fees0 / WAD;
            ghost_owed1[beneficiaryData.beneficiary] += beneficiaryData.shares * fees1 / WAD;
        }

        if (ghost_shares[msg.sender] > 0) {
            uint256 owed0 = ghost_owed0[msg.sender];
            uint256 owed1 = ghost_owed1[msg.sender];

            ghost_claimed0[msg.sender] += owed0;
            ghost_claimed1[msg.sender] += owed1;
            ghost_owed0[msg.sender] = 0;
            ghost_owed1[msg.sender] = 0;

            ghost_totalClaimed0 += owed0;
            ghost_totalClaimed1 += owed1;
            ghost_totalOwed0 -= owed0;
            ghost_totalOwed1 -= owed1;
        }

        vm.prank(msg.sender);
        implementation.collectFees(poolId);

        ghost_totalFees0 += fees0;
        ghost_totalFees1 += fees1;
    }

    function updateBeneficiary() public { }

    function getOwed(
        address beneficiary
    ) public view returns (uint256 owed0, uint256 owed1) {
        uint256 cumulatedFees0 = implementation.getCumulatedFees0(poolId);
        uint256 cumulatedFees1 = implementation.getCumulatedFees1(poolId);

        uint256 lastCumulatedFees0 = implementation.getLastCumulatedFees0(poolId, beneficiary);
        uint256 lastCumulatedFees1 = implementation.getLastCumulatedFees1(poolId, beneficiary);

        owed0 = ((cumulatedFees0 - lastCumulatedFees0) * implementation.getShares(poolId, beneficiary)) / WAD;
        owed1 = ((cumulatedFees1 - lastCumulatedFees1) * implementation.getShares(poolId, beneficiary)) / WAD;
    }
}

contract FeesManagerInvariants is Test {
    FeesManagerHandler public handler;
    FeesManagerImplementation public implementation;
    PoolManagerMock public poolManager;
    TestERC20 public token0;
    TestERC20 public token1;

    BeneficiaryData[] public beneficiaries;
    PoolKey public poolKey;
    PoolId public poolId;

    constructor() {
        token0 = new TestERC20(0);
        token1 = new TestERC20(0);

        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            hooks: IHooks(address(0)),
            tickSpacing: 0
        });
        poolId = poolKey.toId();

        poolManager = new PoolManagerMock(token0, token1);
        implementation = new FeesManagerImplementation(poolManager, token0, token1);

        beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0xaaa), shares: 0.95e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: 0.05e18 });

        handler = new FeesManagerHandler(implementation, poolManager, poolKey, beneficiaries);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.collectFees.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_OwedFeesMatchBalances() public view {
        assertApproxEqRel(
            handler.ghost_totalOwed0(),
            token0.balanceOf(address(implementation)),
            0.001e18,
            "Total owed0 should match token0 balance"
        );
        assertApproxEqRel(
            handler.ghost_totalOwed1(),
            token1.balanceOf(address(implementation)),
            0.001e18,
            "Total owed1 should match token1 balance"
        );
    }

    function invariant_ClaimedMatchBalances() public view {
        for (uint256 i; i != beneficiaries.length; ++i) {
            BeneficiaryData memory beneficiary = beneficiaries[i];
            assertApproxEqRel(
                handler.ghost_claimed0(beneficiary.beneficiary),
                token0.balanceOf(beneficiary.beneficiary),
                0.001e18,
                "Claimed0 should match token0 balance"
            );
            assertApproxEqRel(
                handler.ghost_claimed1(beneficiary.beneficiary),
                token1.balanceOf(beneficiary.beneficiary),
                0.001e18,
                "Claimed1 should match token1 balance"
            );
        }
    }
}
