// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @notice Core pool information for a Rehype-managed pool
 * @param asset Address of the asset token
 * @param numeraire Address of the numeraire token
 * @param buybackDst Address receiving buyback proceeds and beneficiary fees
 */
struct PoolInfo {
    address asset;
    address numeraire;
    address buybackDst;
}

/**
 * @notice Fee distribution percentages for a pool (must sum to WAD)
 * @param assetBuybackPercentWad Percentage of fees used to buy back the asset (in WAD)
 * @param numeraireBuybackPercentWad Percentage of fees used to buy back the numeraire (in WAD)
 * @param beneficiaryPercentWad Percentage of fees allocated to the beneficiary (in WAD)
 * @param lpPercentWad Percentage of fees reinvested as LP liquidity (in WAD)
 */
struct FeeDistributionInfo {
    uint256 assetBuybackPercentWad;
    uint256 numeraireBuybackPercentWad;
    uint256 beneficiaryPercentWad;
    uint256 lpPercentWad;
}

/**
 * @notice Accumulated hook fees for a pool
 * @param fees0 Pending distributable fees in currency0
 * @param fees1 Pending distributable fees in currency1
 * @param beneficiaryFees0 Accumulated beneficiary fees in currency0
 * @param beneficiaryFees1 Accumulated beneficiary fees in currency1
 * @param airlockOwnerFees0 Accumulated airlock owner fees in currency0
 * @param airlockOwnerFees1 Accumulated airlock owner fees in currency1
 * @param customFee Custom swap fee rate applied to the pool
 */
struct HookFees {
    uint128 fees0;
    uint128 fees1;
    uint128 beneficiaryFees0;
    uint128 beneficiaryFees1;
    uint128 airlockOwnerFees0;
    uint128 airlockOwnerFees1;
    uint24 customFee;
}

/**
 * @notice Result of a simulated swap used during fee rebalancing
 * @param amountIn Amount of input token consumed by the swap
 * @param amountOut Amount of output token received from the swap
 * @param fees0 Projected currency0 fees remaining after the swap
 * @param fees1 Projected currency1 fees remaining after the swap
 * @param excess0 Excess currency0 that cannot be deposited as LP
 * @param excess1 Excess currency1 that cannot be deposited as LP
 * @param sqrtPriceX96 Projected pool price after the swap
 * @param success Whether the simulation completed without reverting
 */
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
