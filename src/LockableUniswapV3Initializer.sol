// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { LiquidityAmounts } from "@v4-core-test/utils/LiquidityAmounts.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ERC20, SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { Airlock } from "./Airlock.sol";
import { IPoolInitializer } from "./interfaces/IPoolInitializer.sol";
import { ImmutableAirlock } from "./base/ImmutableAirlock.sol";
import { BeneficiaryData } from "./StreamableFeesLocker.sol";

/**
 * @notice Emitted when a collect event is called
 * @param pool Address of the pool
 * @param beneficiary Address of the beneficiary receiving the fees
 * @param fees0 Amount of fees collected in token0
 * @param fees1 Amount of fees collected in token1
 */
event Collect(address indexed pool, address indexed beneficiary, uint256 fees0, uint256 fees1);

/**
 * @notice Emitted when a new pool is locked
 * @param pool Address of the Uniswap V3 pool
 * @param beneficiaries Array of beneficiaries with their shares
 */
event Lock(address indexed pool, BeneficiaryData[] beneficiaries);

/// @notice Thrown when the caller is not the Pool contract
error OnlyPool();

/// @notice Thrown when the pool is already initialized
error PoolAlreadyInitialized();

/// @notice Thrown when the pool is already exited
error PoolAlreadyExited();

/// @notice Thrown when the pool is locked but collect is called
error PoolLocked();

/// @notice Thrown when the current tick is not sufficient to migrate
error CannotMigrateInsufficientTick(int24 targetTick, int24 currentTick);

/// @notice Thrown when the computed liquidity to mint is zero
error CannotMintZeroLiquidity();

/// @notice Thrown when the specified fee is not set in the Uniswap V3 factory
error InvalidFee(uint24 fee);

/// @notice Thrown when the tick range is misordered
error InvalidTickRangeMisordered(int24 tickLower, int24 tickUpper);

/// @notice Thrown when a tick is not aligned with the tick spacing
error InvalidTickRange(int24 tick, int24 tickSpacing);

/// @notice Thrown when the max share to be sold exceeds the maximum unit
error MaxShareToBeSoldExceeded(uint256 value, uint256 limit);

/// @dev Thrown when the beneficiaries are not in ascending order
error UnorderedBeneficiaries();

/// @notice Thrown when shares are invalid
error InvalidShares();

/// @notice Thrown when total shares are not equal to WAD
error InvalidTotalShares();

/// @notice Thrown when protocol owner shares are invalid
error InvalidProtocolOwnerShares();

/// @notice Thrown when protocol owner beneficiary is not found
error InvalidProtocolOwnerBeneficiary();

/// @dev Constant used to increase precision during calculations
uint256 constant WAD = 1e18;

struct InitData {
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint16 numPositions;
    uint256 maxShareToBeSold;
    BeneficiaryData[] beneficiaries;
}

struct CallbackData {
    address asset;
    address numeraire;
    uint24 fee;
}

enum PoolStatus {
    Uninitialized,
    Initialized,
    Locked,
    Exited
}

struct PoolState {
    address asset;
    address numeraire;
    int24 tickLower;
    int24 tickUpper;
    uint256 maxShareToBeSold;
    uint256 totalTokensOnBondingCurve;
    BeneficiaryData[] beneficiaries;
    LpPosition[] lpPositions;
    PoolStatus status;
}

struct LpPosition {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint16 id;
}

contract LockableUniswapV3Initializer is IPoolInitializer, IUniswapV3MintCallback, ImmutableAirlock {
    using SafeTransferLib for ERC20;

    /// @notice Address of the Uniswap V3 factory
    IUniswapV3Factory public immutable factory;

    /// @notice Returns the state of a pool
    mapping(address pool => PoolState state) public getState;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param factory_ Address of the Uniswap V3 factory
     */
    constructor(address airlock_, IUniswapV3Factory factory_) ImmutableAirlock(airlock_) {
        factory = factory_;
    }

    /// @inheritdoc IPoolInitializer
    function initialize(
        address asset,
        address numeraire,
        uint256 totalTokensOnBondingCurve,
        bytes32,
        bytes calldata data
    ) external onlyAirlock returns (address pool) {
        InitData memory initData = abi.decode(data, (InitData));
        (
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint16 numPositions,
            uint256 maxShareToBeSold,
            BeneficiaryData[] memory beneficiaries
        ) = (
            initData.fee,
            initData.tickLower,
            initData.tickUpper,
            initData.numPositions,
            initData.maxShareToBeSold,
            initData.beneficiaries
        );

        require(maxShareToBeSold <= WAD, MaxShareToBeSoldExceeded(maxShareToBeSold, WAD));
        require(tickLower < tickUpper, InvalidTickRangeMisordered(tickLower, tickUpper));

        int24 tickSpacing = factory.feeAmountTickSpacing(fee);
        if (tickSpacing == 0) revert InvalidFee(fee);

        isValidTick(tickLower, tickSpacing);
        isValidTick(tickUpper, tickSpacing);

        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        uint256 numTokensToSell = FullMath.mulDiv(totalTokensOnBondingCurve, maxShareToBeSold, WAD);
        uint256 numTokensToBond = totalTokensOnBondingCurve - numTokensToSell;

        pool = factory.getPool(token0, token1, fee);
        require(getState[pool].status == PoolStatus.Uninitialized, PoolAlreadyInitialized());

        bool isToken0 = asset == token0;

        if (pool == address(0)) {
            pool = factory.createPool(token0, token1, fee);
        }
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(isToken0 ? tickLower : tickUpper);

        try IUniswapV3Pool(pool).initialize(sqrtPriceX96) { } catch { }

        (LpPosition[] memory lpPositions, uint256 reserves) =
            calculateLogNormalDistribution(tickLower, tickUpper, tickSpacing, isToken0, numPositions, numTokensToSell);

        lpPositions[numPositions] =
            calculateLpTail(numPositions, tickLower, tickUpper, isToken0, reserves, numTokensToBond, tickSpacing);

        mintPositions(asset, numeraire, fee, pool, lpPositions, numPositions);

        getState[pool] = PoolState({
            asset: asset,
            numeraire: numeraire,
            tickLower: tickLower,
            tickUpper: tickUpper,
            maxShareToBeSold: maxShareToBeSold,
            totalTokensOnBondingCurve: totalTokensOnBondingCurve,
            beneficiaries: beneficiaries,
            lpPositions: lpPositions,
            status: beneficiaries.length != 0 ? PoolStatus.Locked : PoolStatus.Initialized
        });

        emit Create(pool, asset, numeraire);

        if (beneficiaries.length != 0) {
            _validateBeneficiaries(beneficiaries);
            emit Lock(pool, beneficiaries);
        }
    }

    /// @inheritdoc IPoolInitializer
    function exitLiquidity(
        address pool
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
        require(getState[pool].status == PoolStatus.Initialized, PoolAlreadyExited());
        getState[pool].status = PoolStatus.Exited;

        token0 = IUniswapV3Pool(pool).token0();
        token1 = IUniswapV3Pool(pool).token1();
        int24 tick;
        (sqrtPriceX96, tick,,,,,) = IUniswapV3Pool(pool).slot0();

        address asset = getState[pool].asset;
        bool isToken0 = asset == token0;

        int24 farTick = isToken0 ? getState[pool].tickUpper : getState[pool].tickLower;
        require(asset == token0 ? tick >= farTick : tick <= farTick, CannotMigrateInsufficientTick(farTick, tick));

        uint256 amount0;
        uint256 amount1;
        (amount0, amount1, balance0, balance1) = burnPositionsMultiple(pool, getState[pool].lpPositions);

        fees0 = uint128(balance0 - amount0);
        fees1 = uint128(balance1 - amount1);

        ERC20(token0).safeTransfer(msg.sender, balance0);
        ERC20(token1).safeTransfer(msg.sender, balance1);
    }

    /**
     * @notice Collects fees from a locked Uniswap V3 pool and distributes them to beneficiaries
     * @param pool Address of the Uniswap V3 pool
     * @return fees0ToDistribute Total fees collected in token0
     * @return fees1ToDistribute Total fees collected in token1
     */
    function collectFees(
        address pool
    ) external returns (uint256 fees0ToDistribute, uint256 fees1ToDistribute) {
        require(getState[pool].status == PoolStatus.Locked, PoolLocked());

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        (fees0ToDistribute, fees1ToDistribute) = collectPositionsMultiple(pool, getState[pool].lpPositions);

        BeneficiaryData[] memory beneficiaries = getState[pool].beneficiaries;

        uint256 amount0Distributed;
        uint256 amount1Distributed;
        address beneficiary;
        for (uint256 i; i < beneficiaries.length; ++i) {
            beneficiary = beneficiaries[i].beneficiary;
            uint256 shares = beneficiaries[i].shares;

            // Calculate share of fees for this beneficiary
            uint256 amount0 = fees0ToDistribute * shares / WAD;
            uint256 amount1 = fees1ToDistribute * shares / WAD;

            amount0Distributed += amount0;
            amount1Distributed += amount1;

            if (i == beneficiaries.length - 1) {
                // Distribute the remaining fees to the last beneficiary
                amount0 += fees0ToDistribute > amount0Distributed ? fees0ToDistribute - amount0Distributed : 0;
                amount1 += fees1ToDistribute > amount1Distributed ? fees1ToDistribute - amount1Distributed : 0;
            }

            ERC20(token0).safeTransfer(beneficiary, amount0);
            ERC20(token1).safeTransfer(beneficiary, amount1);

            emit Collect(pool, beneficiary, amount0, amount1);
        }
    }

    /// @inheritdoc IUniswapV3MintCallback
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        address pool = factory.getPool(callbackData.asset, callbackData.numeraire, callbackData.fee);

        require(msg.sender == pool, OnlyPool());

        ERC20(callbackData.asset).safeTransferFrom(address(airlock), pool, amount0Owed == 0 ? amount1Owed : amount0Owed);
    }

    /// @notice Calculates the final LP position that extends from the far tick to the pool's min/max tick
    /// @dev This position ensures price equivalence between Uniswap v2 and v3 pools beyond the LBP range
    function calculateLpTail(
        uint256 id,
        int24 tickLower,
        int24 tickUpper,
        bool isToken0,
        uint256 reserves,
        uint256 bondingAssetsRemaining,
        int24 tickSpacing
    ) internal pure returns (LpPosition memory lpTail) {
        int24 tailTick = isToken0 ? tickUpper : tickLower;

        uint160 sqrtPriceAtTail = TickMath.getSqrtPriceAtTick(tailTick);

        uint128 lpTailLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceAtTail,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            isToken0 ? bondingAssetsRemaining : reserves,
            isToken0 ? reserves : bondingAssetsRemaining
        );

        int24 posTickLower = isToken0 ? tailTick : alignTickToTickSpacing(isToken0, TickMath.MIN_TICK, tickSpacing);
        int24 posTickUpper = isToken0 ? alignTickToTickSpacing(isToken0, TickMath.MAX_TICK, tickSpacing) : tailTick;

        require(posTickLower < posTickUpper, InvalidTickRangeMisordered(posTickLower, posTickUpper));

        lpTail =
            LpPosition({ tickLower: posTickLower, tickUpper: posTickUpper, liquidity: lpTailLiquidity, id: uint16(id) });
    }

    /// @notice Calculates the distribution of liquidity positions across tick ranges
    /// @dev For example, with 1000 tokens and 10 bins starting at tick 0:
    ///      - Creates positions: [0,10], [1,10], [2,10], ..., [9,10]
    ///      - Each position gets an equal share of tokens (100 tokens each)
    ///      This creates a linear distribution of liquidity across the tick range
    function calculateLogNormalDistribution(
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        bool isToken0,
        uint256 totalPositions,
        uint256 totalAmtToBeSold
    ) internal pure returns (LpPosition[] memory, uint256) {
        int24 farTick = isToken0 ? tickUpper : tickLower;
        int24 closeTick = isToken0 ? tickLower : tickUpper;

        int24 spread = tickUpper - tickLower;

        uint160 farSqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);
        uint256 amountPerPosition = FullMath.mulDiv(totalAmtToBeSold, WAD, totalPositions * WAD);
        uint256 totalAssetsSold;
        LpPosition[] memory newPositions = new LpPosition[](totalPositions + 1);
        uint256 reserves;

        for (uint256 i; i < totalPositions; i++) {
            // calculate the ticks position * 1/n to optimize the division
            int24 startingTick = isToken0
                ? closeTick + int24(uint24(FullMath.mulDiv(i, uint256(uint24(spread)), totalPositions)))
                : closeTick - int24(uint24(FullMath.mulDiv(i, uint256(uint24(spread)), totalPositions)));

            // round the tick to the nearest bin
            startingTick = alignTickToTickSpacing(isToken0, startingTick, tickSpacing);

            if (startingTick != farTick) {
                uint160 startingSqrtPriceX96 = TickMath.getSqrtPriceAtTick(startingTick);

                // if totalAmtToBeSold is 0, we skip the liquidity calculation as we are burning max liquidity
                // in each position
                uint128 liquidity;
                if (totalAmtToBeSold != 0) {
                    liquidity = isToken0
                        ? LiquidityAmounts.getLiquidityForAmount0(startingSqrtPriceX96, farSqrtPriceX96, amountPerPosition)
                        : LiquidityAmounts.getLiquidityForAmount1(farSqrtPriceX96, startingSqrtPriceX96, amountPerPosition);

                    totalAssetsSold += (
                        isToken0
                            ? SqrtPriceMath.getAmount0Delta(startingSqrtPriceX96, farSqrtPriceX96, liquidity, true)
                            : SqrtPriceMath.getAmount1Delta(farSqrtPriceX96, startingSqrtPriceX96, liquidity, true)
                    );

                    // note: we keep track how the theoretical reserves amount at that time to then calculate the breakeven liquidity amount
                    // once we get to the end of the loop, we will know exactly how many of the reserve assets have been raised, and we can
                    // calculate the total amount of reserves after the endTick which makes swappers and LPs indifferent between Uniswap v2 (CPMM) and Uniswap v3 (CLAMM)
                    // we can then bond the tokens to the Uniswap v2 pool by moving them over to the Uniswap v3 pool whenever possible, but there is no rush as it goes up
                    reserves += (
                        isToken0
                            ? SqrtPriceMath.getAmount1Delta(
                                farSqrtPriceX96,
                                startingSqrtPriceX96,
                                liquidity,
                                false // round against the reserves to undercount eventual liquidity
                            )
                            : SqrtPriceMath.getAmount0Delta(
                                startingSqrtPriceX96,
                                farSqrtPriceX96,
                                liquidity,
                                false // round against the reserves to undercount eventual liquidity
                            )
                    );
                }

                newPositions[i] = LpPosition({
                    tickLower: farSqrtPriceX96 < startingSqrtPriceX96 ? farTick : startingTick,
                    tickUpper: farSqrtPriceX96 < startingSqrtPriceX96 ? startingTick : farTick,
                    liquidity: liquidity,
                    id: uint16(i)
                });
            }
        }

        require(totalAssetsSold <= totalAmtToBeSold, CannotMintZeroLiquidity());

        return (newPositions, reserves);
    }

    /**
     * @dev Mint new positions in the Uniswap V3 pool
     * @param asset Address of the token being sold
     * @param numeraire Address of the numeraire token
     * @param fee Fee tier of the Uniswap V3 pool
     * @param pool Address of the Uniswap V3 pool
     * @param newPositions Array of new positions to mint
     * @param numPositions Number of positions to mint (might be cheaper than `newPositions.length`)
     */
    function mintPositions(
        address asset,
        address numeraire,
        uint24 fee,
        address pool,
        LpPosition[] memory newPositions,
        uint16 numPositions
    ) internal {
        for (uint256 i; i <= numPositions; i++) {
            IUniswapV3Pool(pool).mint(
                address(this),
                newPositions[i].tickLower,
                newPositions[i].tickUpper,
                newPositions[i].liquidity,
                abi.encode(CallbackData({ asset: asset, numeraire: numeraire, fee: fee }))
            );
        }
    }

    /**
     * @dev Validates beneficiaries array and ensures protocol owner compliance
     * @param beneficiaries Array of beneficiaries to validate
     */
    function _validateBeneficiaries(
        BeneficiaryData[] memory beneficiaries
    ) internal view {
        address protocolOwner = Airlock(airlock).owner();
        address prevBeneficiary;
        uint256 totalShares;
        bool foundProtocolOwner;

        for (uint256 i; i < beneficiaries.length; i++) {
            BeneficiaryData memory beneficiary = beneficiaries[i];

            // Validate ordering and shares
            require(prevBeneficiary < beneficiary.beneficiary, UnorderedBeneficiaries());
            require(beneficiary.shares > 0, InvalidShares());

            // Check for protocol owner and validate minimum share requirement
            if (beneficiary.beneficiary == protocolOwner) {
                require(beneficiary.shares >= WAD / 20, InvalidProtocolOwnerShares());
                foundProtocolOwner = true;
            }

            prevBeneficiary = beneficiary.beneficiary;
            totalShares += beneficiary.shares;
        }

        require(totalShares == WAD, InvalidTotalShares());
        require(foundProtocolOwner, InvalidProtocolOwnerBeneficiary());
    }

    /**
     * @dev Collects fees from multiple positions in a Uniswap V3 pool
     * @param pool Address of the Uniswap V3 pool
     * @param positions Array of positions to collect fees from
     * @return fees0 Total fees collected in token0
     * @return fees1 Total fees collected in token1
     */
    function collectPositionsMultiple(
        address pool,
        LpPosition[] memory positions
    ) internal returns (uint256 fees0, uint256 fees1) {
        for (uint256 i; i < positions.length; i++) {
            uint256 posFees0;
            uint256 posFees1;

            // you must poke the position via burning it to collecting fees
            IUniswapV3Pool(pool).burn(positions[i].tickLower, positions[i].tickUpper, 0);

            (posFees0, posFees1) = IUniswapV3Pool(pool).collect(
                address(this), positions[i].tickLower, positions[i].tickUpper, type(uint128).max, type(uint128).max
            );

            fees0 += posFees0;
            fees1 += posFees1;
        }
    }

    /**
     * @dev Burns multiple positions in a Uniswap V3 pool and collects fees
     * @param pool Address of the Uniswap V3 pool
     * @param positions Array of positions to burn
     * @return amount0 Amount of token0 received from burning
     * @return amount1 Amount of token1 received from burning
     * @return balance0 Total balance of token0 received
     * @return balance1 Total balance of token1 received
     */
    function burnPositionsMultiple(
        address pool,
        LpPosition[] memory positions
    ) internal returns (uint256 amount0, uint256 amount1, uint128 balance0, uint128 balance1) {
        uint256 posAmount0;
        uint256 posAmount1;
        uint128 posBalance0;
        uint128 posBalance1;

        for (uint256 i; i < positions.length; i++) {
            (posAmount0, posAmount1) =
                IUniswapV3Pool(pool).burn(positions[i].tickLower, positions[i].tickUpper, positions[i].liquidity);
            (posBalance0, posBalance1) = IUniswapV3Pool(pool).collect(
                address(this), positions[i].tickLower, positions[i].tickUpper, type(uint128).max, type(uint128).max
            );

            amount0 += posAmount0;
            amount1 += posAmount1;

            balance0 += posBalance0;
            balance1 += posBalance1;
        }
    }

    /**
     * @dev Checks if a tick is valid according to the tick spacing
     * @param tick Tick to check
     * @param tickSpacing Tick spacing to check against
     */
    function isValidTick(int24 tick, int24 tickSpacing) internal pure {
        if (tick % tickSpacing != 0) revert InvalidTickRange(tick, tickSpacing);
    }

    /**
     * @dev Aligns a tick to the nearest tick spacing
     * @param isToken0 True if we're selling token 0, this impacts the rounding direction
     * @param tick Tick to align
     * @param tickSpacing Tick spacing to align against
     * @return Aligned tick
     */
    function alignTickToTickSpacing(bool isToken0, int24 tick, int24 tickSpacing) internal pure returns (int24) {
        if (isToken0) {
            // Round down if isToken0
            if (tick < 0) {
                // If the tick is negative, we round up (negatively) the negative result to round down
                return (tick - tickSpacing + 1) / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round down
                return tick / tickSpacing * tickSpacing;
            }
        } else {
            // Round up if isToken1
            if (tick < 0) {
                // If the tick is negative, we round down the negative result to round up
                return tick / tickSpacing * tickSpacing;
            } else {
                // Else if positive, we simply round up
                return (tick + tickSpacing - 1) / tickSpacing * tickSpacing;
            }
        }
    }
}
