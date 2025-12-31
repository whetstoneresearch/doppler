// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";

interface IRehypeHook {
    function setFeesForPool(PoolId poolId, uint24 customFee) external;

    function setFeeDistributionForPool(
        PoolId poolId,
        address asset,
        address numeraire,
        address buybackDst,
        uint24 customFee,
        uint256 assetBuybackPercentWad,
        uint256 numeraireBuybackPercentWad,
        uint256 beneficiaryPercentWad,
        uint256 lpPercentWad
    ) external;

    function collectFees(PoolId poolId) external returns (BalanceDelta fees);
}
