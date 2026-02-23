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
        uint256 assetFeesToAssetBuybackWad,
        uint256 assetFeesToNumeraireBuybackWad,
        uint256 assetFeesToBeneficiaryWad,
        uint256 assetFeesToLpWad,
        uint256 numeraireFeesToAssetBuybackWad,
        uint256 numeraireFeesToNumeraireBuybackWad,
        uint256 numeraireFeesToBeneficiaryWad,
        uint256 numeraireFeesToLpWad
    ) external;

    function collectFees(PoolId poolId) external returns (BalanceDelta fees);
}
