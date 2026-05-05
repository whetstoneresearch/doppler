// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolId } from "@v4-core/types/PoolId.sol";

/// @notice Thrown when the fee distribution does not add up to WAD (1e18)
error FeeDistributionMustAddUpToWAD();

/// @notice Thrown when the sender is not authorized to perform an action
error SenderNotAuthorized();

/// @notice Thrown when the sender is not the airlock owner
error SenderNotAirlockOwner();

/// @notice Thrown when the pool manager fee currency is insufficient
error InsufficientFeeCurrency();

/**
 * @notice Emitted when Airlock owner claims fees
 * @param poolId Pool from which fees were claimed
 * @param airlockOwner Address that received the fees
 * @param fees0 Amount of currency0 claimed
 * @param fees1 Amount of currency1 claimed
 */
event AirlockOwnerFeesClaimed(PoolId indexed poolId, address indexed airlockOwner, uint128 fees0, uint128 fees1);

// Constants
/// @dev Maximum swap fee denominator (1e6 = 100%)
uint256 constant MAX_SWAP_FEE = 0.8e6;

/// @dev Epsilon trigger for rebalancing swaps
uint128 constant EPSILON = 1e6;

/// @dev Maximum iterations for rebalancing swap calculation
uint256 constant MAX_REBALANCE_ITERATIONS = 15;

/// @dev Airlock owner fee in basis points (5% = 500 BPS)
uint256 constant AIRLOCK_OWNER_FEE_BPS = 500;

/// @dev Basis points denominator
uint256 constant BPS_DENOMINATOR = 10_000;

/// @notice Thrown when a fee exceeds the maximum swap fee
error FeeTooHigh(uint24 fee);

/// @notice Thrown when startFee < endFee
error InvalidFeeRange(uint24 startFee, uint24 endFee);

/// @notice Thrown when durationSeconds is zero for a descending fee schedule
error InvalidDurationSeconds(uint32 durationSeconds);

/**
 * @notice Emitted when a fee schedule is configured for a pool
 * @param poolId Pool id
 * @param startingTime Schedule start timestamp
 * @param startFee Fee at schedule start
 * @param endFee Terminal fee after schedule completion
 * @param durationSeconds Number of seconds over which fee linearly descends
 */
event FeeScheduleSet(
    PoolId indexed poolId, uint32 startingTime, uint24 startFee, uint24 endFee, uint32 durationSeconds
);

/**
 * @notice Emitted when the custom fee is updated for a pool
 * @param poolId Pool id
 * @param fee New fee
 */
event FeeUpdated(PoolId indexed poolId, uint24 fee);

/**
 * @notice Packed fee schedule for a pool.
 * @dev Fits in a single storage slot to minimize read/write cost.
 * @param startingTime Timestamp where schedule starts
 * @param startFee Fee at schedule start
 * @param endFee Fee at schedule end
 * @param lastFee Last applied fee
 * @param durationSeconds Schedule duration in seconds
 */
struct FeeSchedule {
    uint32 startingTime;
    uint24 startFee;
    uint24 endFee;
    uint24 lastFee;
    uint32 durationSeconds;
}

/**
 * @notice Routing mode for buyback-designated fees
 * @dev DirectBuyback keeps current behavior (immediate transfers to buybackDst).
 * RouteToBeneficiaryFees accrues buyback outputs into beneficiary fee accounting.
 */
enum FeeRoutingMode {
    DirectBuyback,
    RouteToBeneficiaryFees
}

/**
 * @notice Initialization data for a Rehype-managed pool
 * @param numeraire Address of the numeraire token
 * @param buybackDst Address receiving direct buyback proceeds and beneficiary fees
 * @param startFee Fee at schedule start (in millionths, e.g. 5000 = 0.5%)
 * @param endFee Terminal fee after decay completes (in millionths)
 * @param durationSeconds Duration of linear fee decay (0 = no decay, fee stays at startFee)
 * @param startingTime Timestamp when decay begins (0 = use block.timestamp at initialization)
 * @param feeRoutingMode Routing mode for buyback-designated fees
 * @param feeDistributionInfo Fee routing matrix percentages for the pool
 */
struct InitData {
    address numeraire;
    address buybackDst;
    uint24 startFee;
    uint24 endFee;
    uint32 durationSeconds;
    uint32 startingTime;
    FeeRoutingMode feeRoutingMode;
    FeeDistributionInfo feeDistributionInfo;
}

/**
 * @notice Initialization data for a Rehype-managed migrator pool (no fee decay)
 * @param numeraire Address of the numeraire token
 * @param buybackDst Address receiving direct buyback proceeds and beneficiary fees
 * @param customFee Static swap fee (in millionths, e.g. 5000 = 0.5%)
 * @param feeRoutingMode Routing mode for buyback-designated fees
 * @param feeDistributionInfo Fee routing matrix percentages for the pool
 */
struct MigratorInitData {
    address numeraire;
    address buybackDst;
    uint24 customFee;
    FeeRoutingMode feeRoutingMode;
    FeeDistributionInfo feeDistributionInfo;
}

/**
 * @notice Core pool information for a Rehype-managed pool
 * @param asset Address of the asset token
 * @param numeraire Address of the numeraire token
 * @param buybackDst Address receiving direct buyback proceeds and beneficiary fees
 */
struct PoolInfo {
    address asset;
    address numeraire;
    address buybackDst;
}

/**
 * @notice Fee routing matrix percentages for a pool
 * @dev For each source token row (asset fees, numeraire fees), the 4 destination columns must sum to WAD.
 * @param assetFeesToAssetBuybackWad Percentage of asset-denominated fees sent directly as asset buyback
 * @param assetFeesToNumeraireBuybackWad Percentage of asset-denominated fees swapped to numeraire buyback
 * @param assetFeesToBeneficiaryWad Percentage of asset-denominated fees sent to beneficiary accounting
 * @param assetFeesToLpWad Percentage of asset-denominated fees allocated to LP reinvestment
 * @param numeraireFeesToAssetBuybackWad Percentage of numeraire-denominated fees swapped to asset buyback
 * @param numeraireFeesToNumeraireBuybackWad Percentage of numeraire-denominated fees sent directly as numeraire buyback
 * @param numeraireFeesToBeneficiaryWad Percentage of numeraire-denominated fees sent to beneficiary accounting
 * @param numeraireFeesToLpWad Percentage of numeraire-denominated fees allocated to LP reinvestment
 */
struct FeeDistributionInfo {
    uint256 assetFeesToAssetBuybackWad;
    uint256 assetFeesToNumeraireBuybackWad;
    uint256 assetFeesToBeneficiaryWad;
    uint256 assetFeesToLpWad;
    uint256 numeraireFeesToAssetBuybackWad;
    uint256 numeraireFeesToNumeraireBuybackWad;
    uint256 numeraireFeesToBeneficiaryWad;
    uint256 numeraireFeesToLpWad;
}

/**
 * @notice Accumulated hook fees for a pool
 * @param fees0 Pending distributable fees in currency0
 * @param fees1 Pending distributable fees in currency1
 * @param beneficiaryFees0 Accumulated beneficiary fees in currency0
 * @param beneficiaryFees1 Accumulated beneficiary fees in currency1
 * @param airlockOwnerFees0 Accumulated airlock owner fees in currency0
 * @param airlockOwnerFees1 Accumulated airlock owner fees in currency1
 * @param customFee Custom swap fee rate applied to the pool (skipped if fee schedule is active)
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
