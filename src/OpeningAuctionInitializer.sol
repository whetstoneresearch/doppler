// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager, PoolKey, IHooks } from "@v4-core/PoolManager.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { alignTickTowardZero } from "src/libraries/TickLibrary.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { OpeningAuction } from "src/OpeningAuction.sol";
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

/// @notice Emitted when an opening auction transitions to Doppler
event AuctionCompleted(
    address indexed asset,
    int24 clearingTick,
    uint256 tokensSold,
    uint256 proceeds
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
contract OpeningAuctionInitializer is IPoolInitializer, ImmutableAirlock {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for address;

    /// @notice Address of the Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Address of the OpeningAuctionDeployer contract
    OpeningAuctionDeployer public immutable auctionDeployer;

    /// @notice Address of the DopplerDeployer contract
    IDopplerDeployer public immutable dopplerDeployer;

    /// @notice State for each asset's opening auction
    mapping(address asset => OpeningAuctionState state) public getState;

    /// @param airlock_ Address of the Airlock contract
    /// @param poolManager_ Address of the Uniswap V4 PoolManager
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
        bool isToken0 = asset < numeraire;

        // Validate token order matches what we expect
        if (isToken0 && asset > numeraire) revert InvalidTokenOrder();
        if (!isToken0 && asset < numeraire) revert InvalidTokenOrder();

        // Calculate token split: auction gets incentiveShare + sale tokens
        // Doppler gets the rest
        uint256 auctionTokens = numTokensToSell; // All tokens initially go to auction for simplicity
        uint256 dopplerTokens = 0; // Will receive unsold tokens after auction

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
        asset.safeTransferFrom(address(airlock), address(auctionHook), auctionTokens);

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

        emit Create(address(auctionHook), asset, numeraire);

        return address(auctionHook);
    }

    /// @notice Complete the auction and transition to Doppler
    /// @dev Can be called by anyone after auction duration or when early exit conditions are met
    /// @dev This function settles the auction (if not already settled) and deploys Doppler
    /// @param asset The asset token address
    function completeAuction(address asset) external {
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
        uint256 unsoldTokens = state.isToken0 ? balance0 : balance1;

        // Decode and modify Doppler data to use clearing tick as starting tick
        bytes memory modifiedDopplerData = _modifyDopplerStartingTick(
            state.dopplerInitData,
            clearingTick
        );

        // Deploy Doppler hook
        bytes32 dopplerSalt = keccak256(abi.encodePacked(asset, "doppler"));
        Doppler doppler = dopplerDeployer.deploy(unsoldTokens, dopplerSalt, modifiedDopplerData);
        state.dopplerHook = address(doppler);

        // Create Doppler pool key
        // Use Doppler's tick spacing (from dopplerData), not the auction's tick spacing
        // The auction may use wider tick spacing for coarser price discovery,
        // but Doppler requires tick spacing <= 30
        int24 dopplerTickSpacing = _extractDopplerTickSpacing(state.dopplerInitData);
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

        // Initialize Doppler pool at clearing tick
        poolManager.initialize(dopplerPoolKey, TickMath.getSqrtPriceAtTick(clearingTick));

        state.status = OpeningAuctionStatus.DopplerActive;

        emit AuctionCompleted(asset, clearingTick, tokensSold, proceeds);
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
        // Find the asset for this target
        // Target could be either the auction hook or doppler hook
        // We need to iterate through states to find it
        // For simplicity, assume target is passed correctly

        // Try to find the asset by checking if target matches any known hook
        // This is a simplified implementation - in production you might want
        // a reverse mapping

        // Delegate to Doppler's migrate
        return Doppler(payable(target)).migrate(address(airlock));
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

    /// @notice Modify Doppler init data to use a new starting tick
    function _modifyDopplerStartingTick(
        bytes memory dopplerData,
        int24 newStartingTick
    ) internal pure returns (bytes memory) {
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

        // Re-encode with new starting tick
        return abi.encode(
            minimumProceeds,
            maximumProceeds,
            startingTime,
            endingTime,
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
