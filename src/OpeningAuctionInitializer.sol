// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { IPoolManager, PoolKey, IHooks } from "@v4-core/PoolManager.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { ReentrancyGuard } from "@solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { alignTickTowardZero, alignTick } from "src/libraries/TickLibrary.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig, AuctionPhase } from "src/interfaces/IOpeningAuction.sol";
import { Doppler } from "src/initializers/Doppler.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";

/// @notice Status of an opening auction
enum OpeningAuctionStatus {
    Uninitialized,
    AuctionActive,
    DopplerActive,
    Exited
}

/// @notice Init data for the opening auction initializer
/// @param auctionConfig Configuration for the opening auction
/// @param dopplerData Encoded Doppler parameters (startingTick will be overwritten with clearing price)
struct OpeningAuctionInitData {
    OpeningAuctionConfig auctionConfig;
    bytes dopplerData;
}

/// @notice State of an opening auction
struct OpeningAuctionState {
    address numeraire;
    uint256 auctionStartTime;
    uint256 auctionEndTime;
    uint256 auctionTokens;
    uint256 dopplerTokens;
    OpeningAuctionStatus status;
    address openingAuctionHook;
    address dopplerHook;
    PoolKey openingAuctionPoolKey;
    bytes dopplerInitData;
    bool isToken0;
}

/// @notice Thrown when token order is invalid
error InvalidTokenOrder();

/// @notice Thrown when auction is not active
error AuctionNotActive();

/// @notice Thrown when auction is not complete
error AuctionNotComplete();

/// @notice Thrown when Doppler is not active
error DopplerNotActive();

/// @notice Thrown when auction tick spacing is not compatible with Doppler tick spacing
/// @param auctionTickSpacing The tick spacing configured for the opening auction
/// @param dopplerTickSpacing The tick spacing configured for Doppler
error IncompatibleTickSpacing(int24 auctionTickSpacing, int24 dopplerTickSpacing);

/// @notice Thrown when asset has already been initialized
error AssetAlreadyInitialized();

/// @notice Thrown when isToken0 in dopplerData doesn't match derived value
error IsToken0Mismatch();

/// @notice Thrown when exitLiquidity target is not a valid Doppler hook
error InvalidExitTarget();

/// @notice Thrown when the auction share is invalid
error InvalidShareToAuctionBps();

/// @notice Thrown when auction allocation rounds to zero
error AuctionAllocationTooSmall();

/// @notice Thrown when an auction has not been initialized
error AuctionNotInitialized();

/// @notice Thrown when an asset has not been initialized
error AssetNotInitialized();

/// @notice Emitted when an opening auction transitions to Doppler
event AuctionCompleted(
    address indexed asset,
    int24 clearingTick,
    uint256 tokensSold,
    uint256 proceeds
);

/// @notice Emitted when proceeds are forwarded to governance
event ProceedsForwarded(address indexed asset, address indexed numeraire, uint256 amount);

/// @notice Emitted when an opening auction is initialized
event AuctionInitialized(
    address indexed asset,
    address indexed numeraire,
    address openingAuctionHook,
    uint256 auctionTokens,
    uint256 auctionDuration,
    int24 minAcceptableTickToken0,
    int24 minAcceptableTickToken1,
    int24 tickSpacing
);

/// @notice Emitted when Doppler is deployed after auction completion
event DopplerDeployed(
    address indexed asset,
    address indexed dopplerHook,
    int24 alignedClearingTick,
    uint256 unsoldTokens
);

/// @notice Emitted when auction status changes
event StatusChanged(
    address indexed asset,
    OpeningAuctionStatus indexed oldStatus,
    OpeningAuctionStatus indexed newStatus
);

/// @title OpeningAuctionDeployer
/// @notice Deploys OpeningAuction hooks using CREATE2
contract OpeningAuctionDeployer {
    IPoolManager public poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Deploy a new OpeningAuction hook
    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external virtual returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuction auction = new OpeningAuction{salt: salt}(
            poolManager,
            msg.sender, // initializer
            auctionTokens,
            config
        );

        return auction;
    }
}

/// @title DopplerDeployerInterface
/// @notice Minimal interface for DopplerDeployer
interface IDopplerDeployer {
    function deploy(uint256 numTokensToSell, bytes32 salt, bytes calldata data) external returns (Doppler);
}

/// @title OpeningAuctionInitializer
/// @notice Initializes an Opening Auction that transitions to a Doppler Dutch auction
/// @author Whetstone Research
/// @custom:security-contact security@whetstone.cc
contract OpeningAuctionInitializer is IPoolInitializer, ImmutableAirlock, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for address;

    uint256 internal constant BPS = 10_000;

    /// @notice Address of the PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Address of the OpeningAuctionDeployer contract
    OpeningAuctionDeployer public immutable auctionDeployer;

    /// @notice Address of the DopplerDeployer contract
    IDopplerDeployer public immutable dopplerDeployer;

    /// @notice State for each asset's opening auction
    mapping(address asset => OpeningAuctionState state) public getState;

    /// @notice Reverse mapping from Doppler hook to asset address
    mapping(address dopplerHook => address asset) public dopplerHookToAsset;

    /// @notice Reverse mapping from Opening Auction hook to asset address
    mapping(address openingAuctionHook => address asset) public openingAuctionHookToAsset;

    /// @param airlock_ Address of the Airlock contract
    /// @param poolManager_ Address of the PoolManager
    /// @param auctionDeployer_ Address of the OpeningAuctionDeployer contract
    /// @param dopplerDeployer_ Address of the DopplerDeployer contract
    constructor(
        address airlock_,
        IPoolManager poolManager_,
        OpeningAuctionDeployer auctionDeployer_,
        IDopplerDeployer dopplerDeployer_
    ) ImmutableAirlock(airlock_) {
        poolManager = poolManager_;
        auctionDeployer = auctionDeployer_;
        dopplerDeployer = dopplerDeployer_;
    }

    /// @inheritdoc IPoolInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 numTokensToSell,
        bytes32 salt,
        bytes calldata data
    ) external onlyAirlock returns (address) {
        // Prevent re-initialization of the same asset
        if (getState[asset].status != OpeningAuctionStatus.Uninitialized) {
            revert AssetAlreadyInitialized();
        }

        OpeningAuctionInitData memory initData = abi.decode(data, (OpeningAuctionInitData));
        OpeningAuctionConfig memory config = initData.auctionConfig;

        // Validate tick spacing compatibility with Doppler
        // The auction tick spacing must be a multiple of the Doppler tick spacing
        // to ensure the clearing tick is valid for Doppler pool initialization
        int24 dopplerTickSpacing = _extractDopplerTickSpacing(initData.dopplerData);
        if (config.tickSpacing % dopplerTickSpacing != 0) {
            revert IncompatibleTickSpacing(config.tickSpacing, dopplerTickSpacing);
        }

        // Determine token ordering
        if (asset == numeraire) revert InvalidTokenOrder();
        bool isToken0 = asset < numeraire;

        // Validate isToken0 in dopplerData matches derived value
        bool dopplerIsToken0 = _extractDopplerIsToken0(initData.dopplerData);
        if (dopplerIsToken0 != isToken0) {
            revert IsToken0Mismatch();
        }

        uint256 shareToAuctionBps = config.shareToAuctionBps;
        if (shareToAuctionBps == 0 || shareToAuctionBps > BPS) {
            revert InvalidShareToAuctionBps();
        }

        uint256 auctionTokens = FullMath.mulDiv(numTokensToSell, shareToAuctionBps, BPS);
        uint256 dopplerTokens = numTokensToSell - auctionTokens;
        if (auctionTokens == 0) revert AuctionAllocationTooSmall();

        // Deploy Opening Auction hook
        OpeningAuction auctionHook = auctionDeployer.deploy(
            auctionTokens,
            salt,
            abi.encode(config)
        );

        // Set isToken0 on the hook
        auctionHook.setIsToken0(isToken0);

        // Create Opening Auction pool key
        PoolKey memory auctionPoolKey = PoolKey({
            currency0: isToken0 ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: isToken0 ? Currency.wrap(numeraire) : Currency.wrap(asset),
            hooks: IHooks(auctionHook),
            fee: config.fee,
            tickSpacing: config.tickSpacing
        });

        // Transfer tokens to auction hook
        asset.safeTransferFrom(address(airlock), address(auctionHook), numTokensToSell);

        // Initialize the Opening Auction pool at extreme price boundary
        // isToken0=true: start at MAX_TICK (highest price for token0, price moves down)
        // isToken0=false: start at MIN_TICK (lowest price, price moves up)
        int24 startingTick = alignTickTowardZero(
            isToken0 ? TickMath.MAX_TICK : TickMath.MIN_TICK,
            config.tickSpacing
        );

        poolManager.initialize(auctionPoolKey, TickMath.getSqrtPriceAtTick(startingTick));

        // Store state
        getState[asset] = OpeningAuctionState({
            numeraire: numeraire,
            auctionStartTime: block.timestamp,
            auctionEndTime: block.timestamp + config.auctionDuration,
            auctionTokens: auctionTokens,
            dopplerTokens: dopplerTokens,
            status: OpeningAuctionStatus.AuctionActive,
            openingAuctionHook: address(auctionHook),
            dopplerHook: address(0),
            openingAuctionPoolKey: auctionPoolKey,
            dopplerInitData: initData.dopplerData,
            isToken0: isToken0
        });

        // Store reverse mapping for exitLiquidity validation (Airlock passes this address)
        openingAuctionHookToAsset[address(auctionHook)] = asset;

        emit Create(address(auctionHook), asset, numeraire);
        
        emit AuctionInitialized(
            asset,
            numeraire,
            address(auctionHook),
            auctionTokens,
            config.auctionDuration,
            config.minAcceptableTickToken0,
            config.minAcceptableTickToken1,
            config.tickSpacing
        );

        return address(auctionHook);
    }

    /// @notice Complete the auction and transition to Doppler
    /// @dev Can be called by anyone after auction duration or when early exit conditions are met
    /// @dev This function settles the auction (if not already settled) and deploys Doppler
    /// @param asset The asset token address
    /// @param dopplerSalt Salt for the CREATE2 Doppler deployment (must yield a valid hook address)
    function completeAuction(address asset, bytes32 dopplerSalt) external nonReentrant {
        OpeningAuctionState storage state = getState[asset];

        if (state.status != OpeningAuctionStatus.AuctionActive) revert AuctionNotActive();

        OpeningAuction auctionHook = OpeningAuction(payable(state.openingAuctionHook));

        // Settle the auction if not already settled
        // settleAuction() will revert if conditions aren't met (time not passed, early exit not triggered)
        if (auctionHook.phase() != AuctionPhase.Settled) {
            auctionHook.settleAuction();
        }

        // Get clearing tick and migrate assets
        int24 clearingTick = auctionHook.clearingTick();
        uint256 tokensSold = auctionHook.totalTokensSold();
        uint256 proceeds = auctionHook.totalProceeds();

        // Migrate assets from auction hook to this contract
        (
            ,
            address token0,
            ,
            uint128 balance0,
            address token1,
            ,
            uint128 balance1
        ) = auctionHook.migrate(address(this));

        // Calculate tokens for Doppler (unsold from auction minus incentives already distributed)
        address assetToken = state.isToken0 ? token0 : token1;
        address numeraireToken = state.isToken0 ? token1 : token0;
        uint256 unsoldTokens = state.isToken0 ? balance0 : balance1;
        uint256 numeraireBalance = state.isToken0 ? balance1 : balance0;

        (, , address governance,,,,,,,) = airlock.getAssetData(asset);

        // Forward proceeds (numeraire) to governance
        if (numeraireBalance > 0) {
            numeraireToken.safeTransfer(governance, numeraireBalance);
            emit ProceedsForwarded(asset, numeraireToken, numeraireBalance);
        }

        // Align clearing tick to Doppler's tick spacing
        // The clearing tick from the auction may not be aligned to Doppler's tick spacing
        int24 dopplerTickSpacing = _extractDopplerTickSpacing(state.dopplerInitData);
        int24 alignedClearingTick = alignTick(state.isToken0, clearingTick, dopplerTickSpacing);
        int24 minAligned = alignTickTowardZero(TickMath.MIN_TICK, dopplerTickSpacing);
        int24 maxAligned = alignTickTowardZero(TickMath.MAX_TICK, dopplerTickSpacing);

        if (alignedClearingTick < minAligned) alignedClearingTick = minAligned;
        if (alignedClearingTick > maxAligned) alignedClearingTick = maxAligned;

        // Decode and modify Doppler data to use aligned clearing tick as starting tick
        bytes memory modifiedDopplerData = _modifyDopplerStartingTick(
            state.dopplerInitData,
            alignedClearingTick
        );

        // Deploy Doppler hook
        Doppler doppler = dopplerDeployer.deploy(unsoldTokens, dopplerSalt, modifiedDopplerData);
        state.dopplerHook = address(doppler);

        // Store reverse mapping for exitLiquidity validation
        dopplerHookToAsset[address(doppler)] = asset;

        // Create Doppler pool key
        // Use Doppler's tick spacing (from dopplerData), not the auction's tick spacing
        // The auction may use wider tick spacing for coarser price discovery,
        // but Doppler requires tick spacing <= 30
        PoolKey memory dopplerPoolKey = PoolKey({
            currency0: state.openingAuctionPoolKey.currency0,
            currency1: state.openingAuctionPoolKey.currency1,
            hooks: IHooks(doppler),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: dopplerTickSpacing
        });

        // Transfer tokens to Doppler
        if (unsoldTokens > 0) {
            assetToken.safeTransfer(address(doppler), unsoldTokens);
        }

        // Initialize Doppler pool at aligned clearing tick
        poolManager.initialize(dopplerPoolKey, TickMath.getSqrtPriceAtTick(alignedClearingTick));

        emit DopplerDeployed(asset, address(doppler), alignedClearingTick, unsoldTokens);

        OpeningAuctionStatus oldStatus = state.status;
        state.status = OpeningAuctionStatus.DopplerActive;
        emit StatusChanged(asset, oldStatus, OpeningAuctionStatus.DopplerActive);

        emit AuctionCompleted(asset, alignedClearingTick, tokensSold, proceeds);
    }

    /* -------------------------------------------------------------------------- */
    /*                    Incentive recovery / sweeping helpers                   */
    /* -------------------------------------------------------------------------- */

    function _openingAuctionOrRevert(address asset, bool useAssetNotInitialized)
        internal
        view
        returns (OpeningAuction auction)
    {
        OpeningAuctionState storage state = getState[asset];
        if (state.status == OpeningAuctionStatus.Uninitialized) {
            if (useAssetNotInitialized) revert AssetNotInitialized();
            revert AuctionNotInitialized();
        }
        auction = OpeningAuction(payable(state.openingAuctionHook));
    }

    /// @notice Permissionless recovery for the edge-case where no tick accrued any
    ///         in-range time (i.e., cachedTotalWeightedTimeX128 == 0).
    ///         Sends recovered incentive tokens to the Airlock owner.
    function recoverOpeningAuctionIncentives(address asset) external nonReentrant {
        OpeningAuction auction = _openingAuctionOrRevert(asset, true);
        auction.recoverIncentives(airlock.owner());
    }

    /// @notice Permissionless sweep of remaining/unclaimed incentive tokens after
    ///         the claim window ends. Sends swept incentives to the Airlock owner.
    function sweepOpeningAuctionIncentives(address asset) external nonReentrant {
        OpeningAuction auction = _openingAuctionOrRevert(asset, true);
        auction.sweepUnclaimedIncentives(airlock.owner());
    }

    /// @notice Sweep unclaimed auction incentives after the claim window
    /// @param asset The asset token address
    /// @param recipient The recipient of swept incentives
    function sweepAuctionIncentives(address asset, address recipient) external onlyAirlock {
        OpeningAuction auction = _openingAuctionOrRevert(asset, false);
        auction.sweepUnclaimedIncentives(recipient);
    }

    /// @notice Recover incentive tokens when no positions earned time
    /// @param asset The asset token address
    /// @param recipient The recipient of recovered incentives
    function recoverAuctionIncentives(address asset, address recipient) external onlyAirlock {
        OpeningAuction auction = _openingAuctionOrRevert(asset, false);
        auction.recoverIncentives(recipient);
    }

    /// @inheritdoc IPoolInitializer
    function exitLiquidity(
        address target
    )
        external
        onlyAirlock
        returns (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        )
    {
        // Try to resolve asset from Doppler hook mapping first
        address asset = dopplerHookToAsset[target];
        // If not found, try the Opening Auction hook mapping (Airlock passes this address)
        if (asset == address(0)) {
            asset = openingAuctionHookToAsset[target];
        }
        if (asset == address(0)) {
            revert InvalidExitTarget();
        }

        // Validate state is DopplerActive
        OpeningAuctionState storage state = getState[asset];
        if (state.status != OpeningAuctionStatus.DopplerActive) {
            revert DopplerNotActive();
        }

        // Get the actual Doppler hook address
        address doppler = state.dopplerHook;
        if (doppler == address(0)) {
            revert DopplerNotActive();
        }

        // Update status to Exited
        OpeningAuctionStatus oldStatus = state.status;
        state.status = OpeningAuctionStatus.Exited;
        emit StatusChanged(asset, oldStatus, OpeningAuctionStatus.Exited);

        // Delegate to the actual Doppler hook's migrate (NOT the target passed by Airlock)
        return Doppler(payable(doppler)).migrate(address(airlock));
    }

    /// @notice Get the Doppler hook address for an asset
    /// @param asset The asset token address
    /// @return The Doppler hook address (or address(0) if not yet transitioned)
    function getDopplerHook(address asset) external view returns (address) {
        return getState[asset].dopplerHook;
    }

    /// @notice Get the Opening Auction hook address for an asset
    /// @param asset The asset token address
    /// @return The Opening Auction hook address
    function getOpeningAuctionHook(address asset) external view returns (address) {
        return getState[asset].openingAuctionHook;
    }

    /// @notice Extract the tick spacing from Doppler init data
    /// @param dopplerData The encoded Doppler initialization data
    /// @return tickSpacing The tick spacing configured for Doppler
    function _extractDopplerTickSpacing(bytes memory dopplerData) internal pure returns (int24 tickSpacing) {
        (,,,,,,,,,,, tickSpacing) = abi.decode(
            dopplerData,
            (uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, uint24, int24)
        );
    }

    /// @notice Extract isToken0 from Doppler init data
    /// @param dopplerData The encoded Doppler initialization data
    /// @return isToken0 Whether the asset is token0
    function _extractDopplerIsToken0(bytes memory dopplerData) internal pure returns (bool isToken0) {
        (,,,,,,,, isToken0,,,) = abi.decode(
            dopplerData,
            (uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, uint24, int24)
        );
    }

    /// @notice Modify Doppler init data to use a new starting tick and adjust timing
    /// @dev Also updates startingTime/endingTime to ensure Doppler can be initialized
    ///      even if the original timing has passed during the auction
    function _modifyDopplerStartingTick(
        bytes memory dopplerData,
        int24 newStartingTick
    ) internal view returns (bytes memory) {
        // Decode Doppler data
        (
            uint256 minimumProceeds,
            uint256 maximumProceeds,
            uint256 startingTime,
            uint256 endingTime,
            , // startingTick - will be replaced
            int24 endingTick,
            uint256 epochLength,
            int24 gamma,
            bool isToken0,
            uint256 numPDSlugs,
            uint24 lpFee,
            int24 tickSpacing
        ) = abi.decode(
            dopplerData,
            (uint256, uint256, uint256, uint256, int24, int24, uint256, int24, bool, uint256, uint24, int24)
        );

        // Calculate original duration to preserve the intended sale duration
        uint256 originalDuration = endingTime - startingTime;

        // If the original startingTime has passed, shift timing forward
        // Add 1 second buffer to ensure startingTime > block.timestamp check passes
        uint256 newStartingTime = startingTime;
        uint256 newEndingTime = endingTime;
        if (block.timestamp >= startingTime) {
            newStartingTime = block.timestamp + 1;
            newEndingTime = newStartingTime + originalDuration;
        }

        // Re-encode with new starting tick and adjusted timing
        return abi.encode(
            minimumProceeds,
            maximumProceeds,
            newStartingTime,
            newEndingTime,
            newStartingTick, // Use clearing tick as starting tick
            endingTick,
            epochLength,
            gamma,
            isToken0,
            numPDSlugs,
            lpFee,
            tickSpacing
        );
    }
}
