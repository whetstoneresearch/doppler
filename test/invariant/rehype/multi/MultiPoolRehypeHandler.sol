// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { Pool } from "@v4-core/libraries/Pool.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";

import { RehypeDopplerHook } from "src/dopplerHooks/RehypeDopplerHook.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import { WAD } from "src/types/Wad.sol";
import { AddressSet, LibAddressSet } from "test/invariant/AddressSet.sol";
import { MultiPoolRehypeSetup, PoolConfig } from "test/invariant/rehype/multi/MultiPoolRehypeSetup.sol";

// Minimum sqrt price for swaps
uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

// Maximum sqrt price for swaps
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

/// @title MultiPoolRehypeHandler
/// @notice Handler contract for fuzzing RehypeDopplerHook with multiple pools
/// @dev Tracks per-pool and global ghost variables for invariant verification
contract MultiPoolRehypeHandler is Test {
    using LibAddressSet for AddressSet;

    // ─────────────────────────────────────────────────────────────────────────────
    // Contracts
    // ─────────────────────────────────────────────────────────────────────────────

    RehypeDopplerHook public hook;
    DopplerHookInitializer public initializer;
    IPoolManager public manager;
    PoolSwapTest public swapRouter;
    TestERC20 public numeraire;
    bool public isUsingEth;
    address public buybackDst;
    address public beneficiary1;

    // Pool arrays (set during construction)
    uint256 public numPools;
    PoolKey[] internal _poolKeys;
    PoolId[] internal _poolIds;
    TestERC20[] internal _assets;
    bool[] internal _isToken0;

    // ─────────────────────────────────────────────────────────────────────────────
    // Ghost Variables - Per Pool Tracking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Swap attempts per pool
    mapping(uint256 poolIndex => uint256) public ghost_swapAttemptsPerPool;

    /// @notice Successful swaps per pool
    mapping(uint256 poolIndex => uint256) public ghost_successfulSwapsPerPool;

    /// @notice Unexpected reverts per pool
    mapping(uint256 poolIndex => uint256) public ghost_unexpectedRevertsPerPool;

    /// @notice Expected reverts per pool
    mapping(uint256 poolIndex => uint256) public ghost_expectedRevertsPerPool;

    /// @notice Last recorded LP liquidity per pool
    mapping(uint256 poolIndex => uint128) public ghost_lastLiquidityPerPool;

    /// @notice Fee distribution changes per pool
    mapping(uint256 poolIndex => uint256) public ghost_feeDistributionChangesPerPool;

    /// @notice Fee collections per pool
    mapping(uint256 poolIndex => uint256) public ghost_feeCollectionsPerPool;

    /// @notice Buy swaps per pool
    mapping(uint256 poolIndex => uint256) public ghost_buySwapsPerPool;

    /// @notice Sell swaps per pool
    mapping(uint256 poolIndex => uint256) public ghost_sellSwapsPerPool;

    // ─────────────────────────────────────────────────────────────────────────────
    // Ghost Variables - Global Tracking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Total swap attempts across all pools
    uint256 public ghost_totalSwapAttemptsAllPools;

    /// @notice Total successful swaps across all pools
    uint256 public ghost_totalSuccessfulSwapsAllPools;

    /// @notice Total unexpected reverts across all pools (BUG INDICATOR - should be 0)
    uint256 public ghost_totalUnexpectedRevertsAllPools;

    /// @notice Total expected reverts across all pools
    uint256 public ghost_totalExpectedRevertsAllPools;

    /// @notice Cross-pool swap operations count
    uint256 public ghost_crossPoolSwapCount;

    /// @notice Total fee distribution changes across all pools
    uint256 public ghost_totalFeeDistributionChanges;

    /// @notice Total fee collections across all pools
    uint256 public ghost_totalFeeCollections;

    // ─────────────────────────────────────────────────────────────────────────────
    // Actor Management
    // ─────────────────────────────────────────────────────────────────────────────

    AddressSet internal actors;
    address internal currentActor;

    /// @notice Asset balance per actor per pool
    mapping(address actor => mapping(uint256 poolIndex => uint256 balance)) public actorAssetBalancePerPool;

    // ─────────────────────────────────────────────────────────────────────────────
    // Debug Tracking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Collected revert selectors for debugging
    bytes4[] public revertSelectors;

    // ─────────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Create a new actor from msg.sender
    modifier createActor() {
        currentActor = msg.sender;
        actors.add(msg.sender);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    /// @notice Use an existing actor based on seed
    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors.rand(actorIndexSeed);
        if (currentActor == address(0)) {
            currentActor = msg.sender;
            actors.add(msg.sender);
        }
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────────

    constructor(MultiPoolRehypeSetup setup) {
        hook = setup.rehypeDopplerHook();
        initializer = setup.initializer();
        manager = setup.getManager();
        swapRouter = setup.getSwapRouter();
        numeraire = setup.numeraire();
        isUsingEth = setup.isUsingEth();
        buybackDst = setup.buybackDst();
        beneficiary1 = setup.beneficiary1();

        numPools = setup.getPoolCount();

        // Copy pool data
        for (uint256 i = 0; i < numPools; i++) {
            _poolKeys.push(setup.getPoolKey(i));
            _poolIds.push(setup.getPoolId(i));
            _assets.push(setup.getAsset(i));
            _isToken0.push(setup.getIsToken0(i));

            // Initialize ghost liquidity tracking
            (,, uint128 liquidity,) = hook.getPosition(_poolIds[i]);
            ghost_lastLiquidityPerPool[i] = liquidity;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Pool-Targeted Swap Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Buy asset on a specific pool
    /// @param poolIndex Index of pool to swap on (bounded internally)
    /// @param amount Amount of numeraire to spend
    function buyOnPool(uint256 poolIndex, uint256 amount) public createActor {
        poolIndex = bound(poolIndex, 0, numPools - 1);
        amount = bound(amount, 0.001 ether, 10 ether);

        _incrementSwapAttempts(poolIndex);

        // Provide numeraire to actor
        _provideNumeraire(amount);

        // Buy: swap numeraire for asset
        bool isToken0 = _isToken0[poolIndex];
        bool zeroForOne = !isToken0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        _executeSwapOnPool(poolIndex, params, amount, true);
    }

    /// @notice Sell asset on a specific pool
    /// @param poolIndex Index of pool to swap on
    /// @param seed Used for actor selection and amount determination
    function sellOnPool(uint256 poolIndex, uint256 seed) public useActor(seed) {
        poolIndex = bound(poolIndex, 0, numPools - 1);

        // Skip if actor has no assets for this pool
        uint256 balance = actorAssetBalancePerPool[currentActor][poolIndex];
        if (balance == 0) return;

        uint256 amount = bound(seed, 1, balance);

        _incrementSwapAttempts(poolIndex);

        TestERC20 asset = _assets[poolIndex];
        asset.approve(address(swapRouter), amount);

        // Sell: swap asset for numeraire
        bool isToken0 = _isToken0[poolIndex];
        bool zeroForOne = isToken0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        _executeSwapOnPool(poolIndex, params, 0, false);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Cross-Pool Operations
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Execute swaps on two different pools in sequence
    /// @param seed Used for pool selection and amounts
    function swapCrossPool(uint256 seed) public createActor {
        uint256 poolA = bound(seed, 0, numPools - 1);
        uint256 poolB = (poolA + 1) % numPools;
        uint256 amount = bound(seed >> 8, 0.1 ether, 1 ether);

        // Swap on pool A (buy)
        _provideNumeraire(amount);
        _incrementSwapAttempts(poolA);

        bool isToken0A = _isToken0[poolA];
        IPoolManager.SwapParams memory paramsA = IPoolManager.SwapParams({
            zeroForOne: !isToken0A,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: !isToken0A ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        _executeSwapOnPool(poolA, paramsA, amount, true);

        // Swap on pool B (buy)
        _provideNumeraire(amount);
        _incrementSwapAttempts(poolB);

        bool isToken0B = _isToken0[poolB];
        IPoolManager.SwapParams memory paramsB = IPoolManager.SwapParams({
            zeroForOne: !isToken0B,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: !isToken0B ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        _executeSwapOnPool(poolB, paramsB, amount, true);

        ghost_crossPoolSwapCount++;
    }

    /// @notice Swap on all pools in round-robin fashion
    /// @param iterations Number of complete cycles through all pools
    function swapAllPoolsRoundRobin(uint8 iterations) public createActor {
        iterations = uint8(bound(iterations, 1, 5));

        for (uint8 iter = 0; iter < iterations; iter++) {
            for (uint256 i = 0; i < numPools; i++) {
                uint256 amount = 0.5 ether;
                _provideNumeraire(amount);
                _incrementSwapAttempts(i);

                bool isToken0 = _isToken0[i];
                IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                    zeroForOne: !isToken0,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                });
                _executeSwapOnPool(i, params, amount, true);
            }
        }

        ghost_crossPoolSwapCount += iterations;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Pool-Specific Configuration
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Change fee distribution on a specific pool
    /// @param poolIndex Pool to modify
    /// @param assetBuyback Fuzzed percentage for asset buyback
    /// @param numeraireBuyback Fuzzed percentage for numeraire buyback
    /// @param beneficiary Fuzzed percentage for beneficiary
    function changePoolFeeDistribution(
        uint256 poolIndex,
        uint256 assetBuyback,
        uint256 numeraireBuyback,
        uint256 beneficiary
    ) public {
        poolIndex = bound(poolIndex, 0, numPools - 1);

        // Bound to create valid distribution
        assetBuyback = bound(assetBuyback, 0, WAD);
        uint256 remaining = WAD - assetBuyback;
        numeraireBuyback = bound(numeraireBuyback, 0, remaining);
        remaining = remaining - numeraireBuyback;
        beneficiary = bound(beneficiary, 0, remaining);
        uint256 lp = remaining - beneficiary;

        vm.prank(beneficiary1);
        try hook.setFeeDistributionByBeneficiary(_poolIds[poolIndex], assetBuyback, numeraireBuyback, beneficiary, lp) {
            ghost_feeDistributionChangesPerPool[poolIndex]++;
            ghost_totalFeeDistributionChanges++;
        } catch {
            // Expected to fail if not beneficiary or invalid params
        }
    }

    /// @notice Set extreme fee distribution on a specific pool (100% to single category)
    /// @param poolIndex Pool to modify
    /// @param category 0=assetBuyback, 1=numeraireBuyback, 2=beneficiary, 3=lp
    function setExtremePoolFeeDistribution(uint256 poolIndex, uint8 category) public {
        poolIndex = bound(poolIndex, 0, numPools - 1);
        category = uint8(bound(category, 0, 3));

        uint256 assetBuyback;
        uint256 numeraireBuyback;
        uint256 beneficiary;
        uint256 lp;

        if (category == 0) assetBuyback = WAD;
        else if (category == 1) numeraireBuyback = WAD;
        else if (category == 2) beneficiary = WAD;
        else lp = WAD;

        vm.prank(beneficiary1);
        try hook.setFeeDistributionByBeneficiary(_poolIds[poolIndex], assetBuyback, numeraireBuyback, beneficiary, lp) {
            ghost_feeDistributionChangesPerPool[poolIndex]++;
            ghost_totalFeeDistributionChanges++;
        } catch { }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fee Collection
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Collect fees from a specific pool
    /// @param poolIndex Pool to collect from
    function collectFeesFromPool(uint256 poolIndex) public createActor {
        poolIndex = bound(poolIndex, 0, numPools - 1);

        try hook.collectFees(address(_assets[poolIndex])) {
            ghost_feeCollectionsPerPool[poolIndex]++;
            ghost_totalFeeCollections++;
        } catch {
            // Fee collection can fail in certain states
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Stress Testing Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Intensive swaps on a single pool (tests isolation)
    /// @param poolIndex Pool to stress
    /// @param count Number of swaps to perform
    function stressSinglePool(uint256 poolIndex, uint8 count) public createActor {
        poolIndex = bound(poolIndex, 0, numPools - 1);
        count = uint8(bound(count, 5, 20));

        for (uint8 i = 0; i < count; i++) {
            uint256 amount = 0.5 ether;
            _provideNumeraire(amount);
            _incrementSwapAttempts(poolIndex);

            bool isToken0 = _isToken0[poolIndex];
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: !isToken0,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });
            _executeSwapOnPool(poolIndex, params, amount, true);
        }
    }

    /// @notice Rapid alternating swaps across all pools
    /// @param iterations Number of full buy-sell cycles per pool
    function rapidCrossPoolSwaps(uint8 iterations) public createActor {
        iterations = uint8(bound(iterations, 2, 8));

        for (uint8 iter = 0; iter < iterations; iter++) {
            for (uint256 i = 0; i < numPools; i++) {
                // Buy
                uint256 buyAmount = 0.5 ether;
                _provideNumeraire(buyAmount);
                _incrementSwapAttempts(i);

                bool isToken0 = _isToken0[i];
                IPoolManager.SwapParams memory buyParams = IPoolManager.SwapParams({
                    zeroForOne: !isToken0,
                    amountSpecified: -int256(buyAmount),
                    sqrtPriceLimitX96: !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                });
                _executeSwapOnPool(i, buyParams, buyAmount, true);

                // Sell half if we have assets
                uint256 sellAmount = actorAssetBalancePerPool[currentActor][i] / 2;
                if (sellAmount > 0) {
                    _assets[i].approve(address(swapRouter), sellAmount);
                    _incrementSwapAttempts(i);

                    IPoolManager.SwapParams memory sellParams = IPoolManager.SwapParams({
                        zeroForOne: isToken0,
                        amountSpecified: -int256(sellAmount),
                        sqrtPriceLimitX96: isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                    });
                    _executeSwapOnPool(i, sellParams, 0, false);
                }
            }
        }

        ghost_crossPoolSwapCount += iterations;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Edge Case Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Buy tiny amount on a specific pool (near EPSILON)
    /// @param poolIndex Pool to swap on
    function buyTinyAmountOnPool(uint256 poolIndex) public createActor {
        poolIndex = bound(poolIndex, 0, numPools - 1);

        // EPSILON in the hook is 1e6, test around that
        uint256 amount = bound(uint256(keccak256(abi.encode(block.timestamp, msg.sender))), 1, 1e7);

        _provideNumeraire(amount);
        _incrementSwapAttempts(poolIndex);

        bool isToken0 = _isToken0[poolIndex];
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        _executeSwapOnPool(poolIndex, params, amount, true);
    }

    /// @notice Buy large amount on a specific pool (stress test)
    /// @param poolIndex Pool to swap on
    function buyLargeAmountOnPool(uint256 poolIndex) public createActor {
        poolIndex = bound(poolIndex, 0, numPools - 1);

        uint256 amount = bound(uint256(keccak256(abi.encode(block.timestamp, msg.sender))), 100 ether, 1000 ether);

        _provideNumeraire(amount);
        _incrementSwapAttempts(poolIndex);

        bool isToken0 = _isToken0[poolIndex];
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: !isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        _executeSwapOnPool(poolIndex, params, amount, true);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Provide numeraire to current actor
    function _provideNumeraire(uint256 amount) internal {
        if (isUsingEth) {
            deal(currentActor, amount);
        } else {
            deal(address(numeraire), currentActor, amount);
            numeraire.approve(address(swapRouter), amount);
        }
    }

    /// @notice Increment swap attempt counters
    function _incrementSwapAttempts(uint256 poolIndex) internal {
        ghost_swapAttemptsPerPool[poolIndex]++;
        ghost_totalSwapAttemptsAllPools++;
    }

    /// @notice Execute swap on a specific pool with comprehensive error handling
    function _executeSwapOnPool(
        uint256 poolIndex,
        IPoolManager.SwapParams memory params,
        uint256 ethValue,
        bool isBuy
    ) internal {
        PoolKey memory key = _poolKeys[poolIndex];
        PoolId poolId = _poolIds[poolIndex];

        // Capture state before swap
        (,, uint128 liquidityBefore,) = hook.getPosition(poolId);

        try swapRouter.swap{ value: isUsingEth && isBuy ? ethValue : 0 }(
            key, params, PoolSwapTest.TestSettings(false, false), new bytes(0)
        ) returns (BalanceDelta delta) {
            ghost_successfulSwapsPerPool[poolIndex]++;
            ghost_totalSuccessfulSwapsAllPools++;

            if (isBuy) {
                ghost_buySwapsPerPool[poolIndex]++;
                // Track asset received
                bool isToken0 = _isToken0[poolIndex];
                uint256 assetReceived;
                if (isToken0) {
                    assetReceived =
                        delta.amount0() > 0 ? uint256(int256(delta.amount0())) : uint256(int256(-delta.amount0()));
                } else {
                    assetReceived =
                        delta.amount1() > 0 ? uint256(int256(delta.amount1())) : uint256(int256(-delta.amount1()));
                }
                actorAssetBalancePerPool[currentActor][poolIndex] += assetReceived;
            } else {
                ghost_sellSwapsPerPool[poolIndex]++;
                // Track asset sold
                uint256 assetSold = uint256(-params.amountSpecified);
                if (actorAssetBalancePerPool[currentActor][poolIndex] >= assetSold) {
                    actorAssetBalancePerPool[currentActor][poolIndex] -= assetSold;
                }
            }

            // Update ghost liquidity tracking
            (,, uint128 liquidityAfter,) = hook.getPosition(poolId);
            ghost_lastLiquidityPerPool[poolIndex] = liquidityAfter;
        } catch (bytes memory err) {
            _handleSwapError(poolIndex, err);
        }
    }

    /// @notice Categorize swap errors as expected or unexpected
    function _handleSwapError(uint256 poolIndex, bytes memory err) internal {
        bytes4 selector;
        assembly {
            selector := mload(add(err, 0x20))
        }

        revertSelectors.push(selector);

        // Check for wrapped errors (V4 style)
        if (selector == CustomRevert.WrappedError.selector) {
            ghost_expectedRevertsPerPool[poolIndex]++;
            ghost_totalExpectedRevertsAllPools++;
            return;
        }

        // Known acceptable reverts from Pool/TickMath
        if (
            selector == Pool.PriceLimitAlreadyExceeded.selector || selector == Pool.PriceLimitOutOfBounds.selector
                || selector == Pool.PoolNotInitialized.selector || selector == TickMath.InvalidSqrtPrice.selector
                || selector == TickMath.InvalidTick.selector
        ) {
            ghost_expectedRevertsPerPool[poolIndex]++;
            ghost_totalExpectedRevertsAllPools++;
            return;
        }

        // Standard Solidity errors
        if (
            selector == bytes4(keccak256("Panic(uint256)")) || selector == bytes4(keccak256("Error(string)"))
        ) {
            ghost_unexpectedRevertsPerPool[poolIndex]++;
            ghost_totalUnexpectedRevertsAllPools++;
            return;
        }

        // Any other error is unexpected
        ghost_unexpectedRevertsPerPool[poolIndex]++;
        ghost_totalUnexpectedRevertsAllPools++;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Get the number of actors
    function getActorCount() external view returns (uint256) {
        return actors.count();
    }

    /// @notice Get pool key by index
    function getPoolKey(uint256 index) external view returns (PoolKey memory) {
        return _poolKeys[index];
    }

    /// @notice Get pool ID by index
    function getPoolId(uint256 index) external view returns (PoolId) {
        return _poolIds[index];
    }

    /// @notice Get asset by index
    function getAsset(uint256 index) external view returns (TestERC20) {
        return _assets[index];
    }

    /// @notice Get isToken0 by index
    function getIsToken0(uint256 index) external view returns (bool) {
        return _isToken0[index];
    }

    /// @notice Get all revert selectors
    function getRevertSelectors() external view returns (bytes4[] memory) {
        return revertSelectors;
    }

    /// @notice Get revert selector count
    function getRevertSelectorCount() external view returns (uint256) {
        return revertSelectors.length;
    }
}
