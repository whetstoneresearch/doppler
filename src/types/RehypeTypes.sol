// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

struct PoolInfo {
    address asset;
    address numeraire;
    address buybackDst;
}

struct FeeDistributionInfo {
    uint256 assetBuybackPercentWad;
    uint256 numeraireBuybackPercentWad;
    uint256 beneficiaryPercentWad;
    uint256 lpPercentWad;
}

struct HookFees {
    uint128 fees0;
    uint128 fees1;
    uint128 beneficiaryFees0;
    uint128 beneficiaryFees1;
    uint24 customFee;
}

struct SwapSimulation {
    uint256 amountIn;
    uint256 amountOut;
    uint256 fees0;
    uint256 fees1;
    uint256 excess0;
    uint256 excess1;
    uint160 sqrtPriceX96;
    bool success;
}
