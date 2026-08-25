// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { PoolId } from "@v4-core/types/PoolId.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";

/// @notice Thrown when the fee distribution does not add up to WAD (1e18)
error FeeDistributionMustAddUpToWAD();

/// @notice Thrown when the sender is not authorized to perform an action
error SenderNotAuthorized();

/// @notice Thrown when the sender is not the airlock owner
error SenderNotAirlockOwner();

/// @notice Thrown when the pool manager fee currency is insufficient
error InsufficientFeeCurrency();

/// @notice Thrown when fee beneficiaries are configured for DirectBuyback routing
error FeeBeneficiariesNotSupportedInDirectBuyback();

/// @notice Thrown when fee collection by PoolId is attempted for a pool without configured fee beneficiaries
error FeeBeneficiariesNotConfigured();

/// @notice Thrown when integrator fee accounting exceeds uint128
error IntegratorFeeOverflow();

/// @notice Thrown when the integrator fee share exceeds its maximum
error IntegratorFeeShareTooHigh();

/// @notice Thrown when an integrator conversion ratio exceeds its denominator or is nonzero for a zero fee share
error InvalidIntegratorConversionRatio();

/// @notice Thrown when an integrator address is required or invalid
error InvalidIntegrator();

/// @notice Thrown when the sender is not the configured integrator
error SenderNotIntegrator();

/// @notice Thrown when an integrator fee claim destination is the zero address
error InvalidIntegratorClaimDestination();

/// @notice Thrown when the pool is already initialized
error PoolAlreadyInitialized();

/// @notice Thrown when the asset is not one of the PoolKey currencies
error InvalidAsset(address asset);

/// @notice Thrown when the configured numeraire does not match the PoolKey currency paired with the asset
error InvalidNumeraire(address expected, address actual);

/**
 * @notice Emitted when Airlock owner claims fees
 * @param poolId Pool from which fees were claimed
 * @param airlockOwner Address that received the fees
 * @param fees0 Amount of currency0 claimed
 * @param fees1 Amount of currency1 claimed
 */
event AirlockOwnerFeesClaimed(PoolId indexed poolId, address indexed airlockOwner, uint128 fees0, uint128 fees1);

/**
 * @notice Emitted when Rehype fee beneficiaries are configured for a pool
 * @param poolId Pool whose Rehype fees are distributed
 * @param beneficiaries Beneficiaries and their respective WAD shares
 */
event FeeBeneficiariesSet(PoolId indexed poolId, BeneficiaryData[] beneficiaries);

/**
 * @notice Emitted when a pool's immutable integrator fee share is configured
 * @param poolId Pool whose integrator fee share is configured
 * @param feeShare Integrator share of gross Rehype fees
 */
event IntegratorFeeShareSet(PoolId indexed poolId, uint24 feeShare);

/**
 * @notice Emitted when integrator conversion ratios are updated
 * @param poolId Pool whose integrator routing is configured
 * @param assetFeesToNumeraireRatio Ratio of asset fees converted to numeraire
 * @param numeraireFeesToAssetRatio Ratio of numeraire fees converted to asset
 */
event IntegratorConversionRatiosSet(
    PoolId indexed poolId, uint32 assetFeesToNumeraireRatio, uint32 numeraireFeesToAssetRatio
);

/**
 * @notice Emitted when automatic integrator payout is enabled or disabled
 * @param poolId Pool whose integrator routing is configured
 * @param automaticPayout Whether future processed fees are paid automatically instead of accrued
 */
event IntegratorAutomaticPayoutSet(PoolId indexed poolId, bool automaticPayout);

/**
 * @notice Emitted when the integrator role is rotated
 * @param poolId Pool whose integrator changed
 * @param oldIntegrator Previous integrator
 * @param newIntegrator New integrator
 */
event IntegratorSet(PoolId indexed poolId, address indexed oldIntegrator, address indexed newIntegrator);

/**
 * @notice Emitted when integrator fees are claimed
 * @param poolId Pool whose integrator fees were claimed
 * @param integrator Integrator that authorized the claim
 * @param to Address that received the claim
 * @param fees0 Amount of currency0 claimed
 * @param fees1 Amount of currency1 claimed
 */
event IntegratorFeesClaimed(
    PoolId indexed poolId, address indexed integrator, address indexed to, uint128 fees0, uint128 fees1
);

// Constants
/// @dev Maximum swap fee (1e6 = 100%)
uint256 constant MAX_SWAP_FEE = 0.8e6;

/// @dev Maximum integrator share of gross Rehype fees (75%)
uint24 constant MAX_INTEGRATOR_FEE_SHARE = 750_000;

/// @dev Swap fee denominator (1e6 = 100%)
uint256 constant SWAP_FEE_DENOMINATOR = 1e6;

/// @dev Denominator for values expressed in millionths (1e6 = 100%)
uint256 constant MILLIONTHS_DENOMINATOR = 1_000_000;

/// @dev Denominator for integrator conversion ratios (1e9 = 100%)
uint256 constant INTEGRATOR_CONVERSION_RATIO_DENOMINATOR = 1_000_000_000;

/// @dev Epsilon trigger for rebalancing swaps
uint128 constant EPSILON = 1e6;

/// @dev Maximum iterations for rebalancing swap calculation
uint256 constant MAX_REBALANCE_ITERATIONS = 15;

/// @dev Airlock owner fee in basis points (5% = 500 BPS)
uint256 constant AIRLOCK_OWNER_FEE_BPS = 500;

/// @dev Basis points denominator
uint256 constant BPS_DENOMINATOR = 10_000;

/// @dev Storage slot for temporary dev buy fee exemption flag
bytes32 constant DEV_BUY_EXEMPTION_SLOT = keccak256("doppler.rehype.devBuyExemption");

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
 * @notice Packed fee schedule and immutable integrator fee share for a pool.
 * @dev Fits in a single storage slot to minimize read/write cost.
 * @param startingTime Timestamp where schedule starts
 * @param startFee Fee at schedule start
 * @param endFee Fee at schedule end
 * @param lastFee Last applied fee
 * @param durationSeconds Schedule duration in seconds
 * @param integratorFeeShare Immutable integrator share of gross Rehype fees
 */
struct FeeSchedule {
    uint32 startingTime;
    uint24 startFee;
    uint24 endFee;
    uint24 lastFee;
    uint32 durationSeconds;
    uint24 integratorFeeShare;
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
 * @notice Integrator configuration supplied when initializing a pool
 * @dev A zero feeShare requires a zero integrator and zero conversion ratios.
 * @param integrator Address controlling routing configuration and claims and receiving automatic payouts
 * @param feeShare Immutable integrator share of gross Rehype fees
 * @param assetFeesToNumeraireRatio Ratio of asset-denominated integrator fees converted to numeraire
 * @param numeraireFeesToAssetRatio Ratio of numeraire-denominated integrator fees converted to asset
 * @param automaticPayout Whether processed integrator fees are paid automatically
 */
struct IntegratorInitConfig {
    address integrator;
    uint24 feeShare;
    uint32 assetFeesToNumeraireRatio;
    uint32 numeraireFeesToAssetRatio;
    bool automaticPayout;
}

/**
 * @notice Mutable integrator routing configuration for a pool
 * @param integrator Address controlling routing configuration and claims and receiving automatic payouts
 * @param assetFeesToNumeraireRatio Ratio of asset-denominated integrator fees converted to numeraire
 * @param numeraireFeesToAssetRatio Ratio of numeraire-denominated integrator fees converted to asset
 * @param automaticPayout Whether processed fees are paid automatically instead of accrued for claim
 */
struct IntegratorRoutingConfig {
    address integrator;
    uint32 assetFeesToNumeraireRatio;
    uint32 numeraireFeesToAssetRatio;
    bool automaticPayout;
}

/**
 * @notice Initialization data for a Rehype-managed pool
 * @dev Every gross Rehype fee first reserves parallel shares for the current Airlock owner and configured integrator.
 * Only the exact residual enters the fee-distribution config.
 * @param numeraire Address of the numeraire token
 * @param buybackDst Address receiving direct buyback proceeds and legacy empty-array beneficiary claims
 * @param startFee Fee at schedule start (in millionths, e.g. 5000 = 0.5%)
 * @param endFee Terminal fee after decay completes (in millionths)
 * @param durationSeconds Duration of linear fee decay (0 = no decay, fee stays at startFee)
 * @param startingTime Timestamp when decay begins (0 = use block.timestamp at initialization)
 * @param feeRoutingMode Routing mode for buyback-designated fees
 * @param feeDistributionInfo Fee routing matrix percentages for the pool
 * @param feeBeneficiaries Optional ordinary Rehype fee beneficiaries. Requires RouteToBeneficiaryFees and positive
 * shares totaling WAD. The Airlock owner does not need to appear, but if included, it has an ordinary share.
 * @param integratorConfig Integrator fee share and routing configuration
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
    BeneficiaryData[] feeBeneficiaries;
    IntegratorInitConfig integratorConfig;
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
 * @param buybackDst Address receiving direct buyback proceeds and, for legacy pools initialized with an empty
 * fee-beneficiary array, beneficiary fees. Configured beneficiary fees are distributed through FeesManager.
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
    uint64 assetFeesToAssetBuybackWad;
    uint64 assetFeesToNumeraireBuybackWad;
    uint64 assetFeesToBeneficiaryWad;
    uint64 assetFeesToLpWad;
    uint64 numeraireFeesToAssetBuybackWad;
    uint64 numeraireFeesToNumeraireBuybackWad;
    uint64 numeraireFeesToBeneficiaryWad;
    uint64 numeraireFeesToLpWad;
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
 * @notice Integrator fee balances for a pool
 * @dev The containing mapping defines whether balances are pending processing or claimable.
 * @param fees0 Currency0 fees in the balance class
 * @param fees1 Currency1 fees in the balance class
 */
struct IntegratorFees {
    uint128 fees0;
    uint128 fees1;
}

/**
 * @notice Result of a directional swap shared by residual fee-distribution and integrator routing
 * @param residualInputUsed Consumed input attributed to the residual fee-distribution amount
 * @param residualOutput Output attributed to the residual fee-distribution amount
 * @param integratorOutput Output attributed to consumed integrator input
 * @param integratorUnconverted Requested integrator input not consumed and retained in its source currency
 */
struct AggregatedSwapResult {
    uint256 residualInputUsed;
    uint256 residualOutput;
    uint256 integratorOutput;
    uint256 integratorUnconverted;
}

/**
 * @notice Integrator amounts produced by one routing cycle
 * @param settlement0 Currency0 ready for automatic payout or claimable accrual
 * @param settlement1 Currency1 ready for automatic payout or claimable accrual
 * @param unconverted0 Currency0 requested for conversion but retained because it was not consumed
 * @param unconverted1 Currency1 requested for conversion but retained because it was not consumed
 */
struct IntegratorSettlement {
    uint256 settlement0;
    uint256 settlement1;
    uint256 unconverted0;
    uint256 unconverted1;
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
