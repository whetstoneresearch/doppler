// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
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

    mapping(PoolId poolId => mapping(address beneficiary => uint256 claimed0)) public ghost_claimed0;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 claimed1)) public ghost_claimed1;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 owed0)) public ghost_owed0;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 owed1)) public ghost_owed1;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 shares)) public ghost_shares;

    mapping(PoolId poolId => uint256 totalOwed0) public ghost_totalOwed0;
    mapping(PoolId poolId => uint256 totalOwed1) public ghost_totalOwed1;
    mapping(PoolId poolId => uint256 totalFees0) public ghost_totalFees0;
    mapping(PoolId poolId => uint256 totalFees1) public ghost_totalFees1;
    mapping(PoolId poolId => uint256 totalClaimed0) public ghost_totalClaimed0;
    mapping(PoolId poolId => uint256 totalClaimed1) public ghost_totalClaimed1;

    mapping(Currency currency => mapping(address beneficiary => uint256 balance)) public ghost_balanceOf;
    mapping(Currency currency => uint256 owed) public ghost_balanceOwed;

    mapping(PoolId poolId => BeneficiaryData[] beneficiaries) internal _beneficiaries;

    PoolId[] internal _poolIds;
    mapping(PoolId poolId => PoolKey poolKey) public _poolKeys;

    constructor(FeesManagerImplementation implementation_, PoolManagerMock poolManager_) {
        implementation = implementation_;
        poolManager = poolManager_;
    }

    function entrypoint(uint256 fees0, uint256 fees1) public {
        // 2% of the time we store new beneficiaries, 98% of the time we collect fees
        if (fees0 % 100 < 2) {
            return storeBeneficiaries(fees0);
        }

        return collectFees(fees0, fees1);
    }

    /// @dev Cannot let the fuzzer pass random beneficiaries as it'll be too
    function storeBeneficiaries(
        uint256 seed
    ) public {
        TestERC20 token0 = new TestERC20(0);
        TestERC20 token1 = new TestERC20(0);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            hooks: IHooks(address(0)),
            tickSpacing: 0
        });

        PoolId poolId = poolKey.toId();
        _poolKeys[poolId] = poolKey;

        BeneficiaryData[] memory beneficiaries = generateBeneficiaries(seed);

        for (uint256 i; i != beneficiaries.length; ++i) {
            BeneficiaryData memory beneficiary = beneficiaries[i];

            _poolIds.push(poolId);
            _beneficiaries[poolId].push(beneficiary);
            ghost_shares[poolId][beneficiary.beneficiary] = beneficiary.shares;
            implementation.storeBeneficiaries(poolKey, beneficiaries);
        }
    }

    function collectFees(uint256 fees0, uint256 fees1) public {
        PoolId poolId = _poolIds[uint256(keccak256(abi.encode(msg.sender))) % _poolIds.length];

        fees0 = bound(fees0, 0, type(uint48).max);
        fees1 = bound(fees1, 0, type(uint48).max);
        poolManager.setFees(_poolKeys[poolId], fees0, fees1);

        // We assume all fees are owed at the beginning, then we'll adjust if the sender is a beneficiary
        ghost_totalOwed0[poolId] += fees0;
        ghost_totalOwed1[poolId] += fees1;

        // We track the balanced owed for each currency this way to avoid looping through all the pools
        ghost_balanceOwed[_poolKeys[poolId].currency0] += fees0;
        ghost_balanceOwed[_poolKeys[poolId].currency1] += fees1;

        // Dumbest and most straightforward way of tracking fees to compare against the implementation
        for (uint256 i; i != _beneficiaries[poolId].length; ++i) {
            BeneficiaryData memory beneficiaryData = _beneficiaries[poolId][i];
            ghost_owed0[poolId][beneficiaryData.beneficiary] += beneficiaryData.shares * fees0 / WAD;
            ghost_owed1[poolId][beneficiaryData.beneficiary] += beneficiaryData.shares * fees1 / WAD;
        }

        if (ghost_shares[poolId][msg.sender] > 0) {
            uint256 owed0 = ghost_owed0[poolId][msg.sender];
            uint256 owed1 = ghost_owed1[poolId][msg.sender];

            ghost_claimed0[poolId][msg.sender] += owed0;
            ghost_claimed1[poolId][msg.sender] += owed1;
            ghost_owed0[poolId][msg.sender] = 0;
            ghost_owed1[poolId][msg.sender] = 0;

            ghost_balanceOf[_poolKeys[poolId].currency0][msg.sender] += owed0;
            ghost_balanceOf[_poolKeys[poolId].currency1][msg.sender] += owed1;

            ghost_totalClaimed0[poolId] += owed0;
            ghost_totalClaimed1[poolId] += owed1;
            ghost_totalOwed0[poolId] -= owed0;
            ghost_totalOwed1[poolId] -= owed1;
            ghost_balanceOwed[_poolKeys[poolId].currency0] -= owed0;
            ghost_balanceOwed[_poolKeys[poolId].currency1] -= owed1;
        }

        vm.prank(msg.sender);
        implementation.collectFees(poolId);

        ghost_totalFees0[poolId] += fees0;
        ghost_totalFees1[poolId] += fees1;
    }

    function updateBeneficiary(
        address newBeneficiary
    ) public {
        PoolId poolId = _poolIds[uint256(keccak256(abi.encode(msg.sender))) % _poolIds.length];
        implementation.updateBeneficiary(poolId, newBeneficiary);
    }

    function getOwed(PoolId poolId, address beneficiary) public view returns (uint256 owed0, uint256 owed1) {
        uint256 cumulatedFees0 = implementation.getCumulatedFees0(poolId);
        uint256 cumulatedFees1 = implementation.getCumulatedFees1(poolId);

        uint256 lastCumulatedFees0 = implementation.getLastCumulatedFees0(poolId, beneficiary);
        uint256 lastCumulatedFees1 = implementation.getLastCumulatedFees1(poolId, beneficiary);

        owed0 = ((cumulatedFees0 - lastCumulatedFees0) * implementation.getShares(poolId, beneficiary)) / WAD;
        owed1 = ((cumulatedFees1 - lastCumulatedFees1) * implementation.getShares(poolId, beneficiary)) / WAD;
    }

    function getPoolIds() public view returns (PoolId[] memory) {
        return _poolIds;
    }

    function getPoolKey(
        PoolId poolId
    ) public view returns (PoolKey memory) {
        return _poolKeys[poolId];
    }

    function getBeneficiaries(
        PoolId poolId_
    ) public view returns (BeneficiaryData[] memory) {
        return _beneficiaries[poolId_];
    }

    /// @dev We generate an array of beneficiaries ourselves to make sure its valid
    function generateBeneficiaries(
        uint256 seed
    ) private pure returns (BeneficiaryData[] memory beneficiaries) {
        uint256 length = seed % 50 + 1;
        beneficiaries = new BeneficiaryData[](length);

        uint256 S = length * (length + 1) / 2;
        uint96 totalShares;

        for (uint256 i = 1; i != beneficiaries.length; ++i) {
            uint96 shares = uint96((WAD - MIN_PROTOCOL_OWNER_SHARES) * i / S);
            totalShares += shares;

            beneficiaries[i] =
                BeneficiaryData({ beneficiary: address(uint160(uint160(PROTOCOL_OWNER) + i)), shares: shares });
        }

        beneficiaries[0] = BeneficiaryData({ beneficiary: PROTOCOL_OWNER, shares: uint96(WAD - totalShares) });
    }
}

contract FeesManagerInvariants is Test {
    FeesManagerHandler public handler;
    FeesManagerImplementation public implementation;
    PoolManagerMock public poolManager;

    constructor() {
        poolManager = new PoolManagerMock();
        implementation = new FeesManagerImplementation(PROTOCOL_OWNER, poolManager);

        handler = new FeesManagerHandler(implementation, poolManager);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.entrypoint.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));

        // Let's always start with at least one pool with beneficiaries
        handler.storeBeneficiaries(block.timestamp);
    }

    function invariant_OwedFeesMatchBalances() public view {
        PoolId[] memory poolIds = handler.getPoolIds();

        for (uint256 i; i != poolIds.length; ++i) {
            PoolKey memory poolKey = handler.getPoolKey(poolIds[i]);

            assertLe(
                poolKey.currency0.balanceOf(address(implementation)),
                handler.ghost_balanceOwed(poolKey.currency0),
                "Total owed0 should match token0 balance"
            );
            assertLe(
                poolKey.currency1.balanceOf(address(implementation)),
                handler.ghost_balanceOwed(poolKey.currency1),
                "Total owed1 should match token1 balance"
            );
        }
    }

    function invariant_ClaimedMatchBalances() public view {
        PoolId[] memory poolIds = handler.getPoolIds();

        for (uint256 i; i != poolIds.length; ++i) {
            PoolId poolId = poolIds[i];
            PoolKey memory poolKey = handler.getPoolKey(poolId);
            BeneficiaryData[] memory beneficiaries = handler.getBeneficiaries(poolId);

            for (uint256 j; j != beneficiaries.length; ++j) {
                BeneficiaryData memory beneficiary = beneficiaries[j];

                assertApproxEqRel(
                    poolKey.currency0.balanceOf(beneficiary.beneficiary),
                    handler.ghost_balanceOf(poolKey.currency0, beneficiary.beneficiary),
                    0.0001e18,
                    "Claimed0 should match token0 balance"
                );
                assertApproxEqRel(
                    poolKey.currency1.balanceOf(beneficiary.beneficiary),
                    handler.ghost_balanceOf(poolKey.currency1, beneficiary.beneficiary),
                    0.0001e18,
                    "Claimed1 should match token1 balance"
                );
            }
        }
    }
}
