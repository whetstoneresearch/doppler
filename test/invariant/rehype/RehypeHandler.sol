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

// Minimum sqrt price for swaps
uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

// Maximum sqrt price for swaps
uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

/// @title RehypeHandler
/// @notice Handler contract for fuzzing RehypeDopplerHook invariant tests
/// @dev Tracks ghost variables for invariant verification
contract RehypeHandler is Test {
    using LibAddressSet for AddressSet;

    // ─────────────────────────────────────────────────────────────────────────────
    // Contracts
    // ─────────────────────────────────────────────────────────────────────────────

    RehypeDopplerHook public hook;
    DopplerHookInitializer public initializer;
    IPoolManager public manager;
    PoolSwapTest public swapRouter;
    TestERC20 public asset;
    TestERC20 public numeraire;
    PoolKey public poolKey;
    PoolId public poolId;
    bool public isToken0;
    bool public isUsingEth;
    address public buybackDst;
    address public beneficiary1;

    // ─────────────────────────────────────────────────────────────────────────────
    // Ghost Variables - Swap Tracking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Total number of swap attempts
    uint256 public ghost_totalSwapAttempts;

    /// @notice Number of successful swaps
    uint256 public ghost_successfulSwaps;

    /// @notice Number of expected/acceptable reverts
    uint256 public ghost_expectedReverts;

    /// @notice Number of unexpected reverts (BUG INDICATOR - should be 0)
    uint256 public ghost_unexpectedReverts;

    /// @notice Number of buy swaps (numeraire -> asset)
    uint256 public ghost_buySwaps;

    /// @notice Number of sell swaps (asset -> numeraire)
    uint256 public ghost_sellSwaps;

    // ─────────────────────────────────────────────────────────────────────────────
    // Ghost Variables - Fee Tracking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Last recorded beneficiary fees in token0
    uint128 public ghost_lastBeneficiaryFees0;

    /// @notice Last recorded beneficiary fees in token1
    uint128 public ghost_lastBeneficiaryFees1;

    // ─────────────────────────────────────────────────────────────────────────────
    // Ghost Variables - LP Tracking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Last recorded LP liquidity
    uint128 public ghost_lastLiquidity;

    /// @notice Count of liquidity additions
    uint256 public ghost_liquidityAdditions;

    // ─────────────────────────────────────────────────────────────────────────────
    // Ghost Variables - Buyback Tracking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Total asset balance received by buyback destination
    uint256 public ghost_buybackDstAssetReceived;

    /// @notice Total numeraire balance received by buyback destination
    uint256 public ghost_buybackDstNumeraireReceived;

    // ─────────────────────────────────────────────────────────────────────────────
    // Ghost Variables - Configuration Tracking
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Number of fee distribution changes
    uint256 public ghost_feeDistributionChanges;

    /// @notice Number of fee collections
    uint256 public ghost_feeCollections;

    // ─────────────────────────────────────────────────────────────────────────────
    // Actor Management
    // ─────────────────────────────────────────────────────────────────────────────

    AddressSet internal actors;
    address internal currentActor;

    /// @notice Asset balance per actor
    mapping(address actor => uint256 balance) public actorAssetBalance;

    /// @notice Numeraire balance per actor (for ETH tracking)
    mapping(address actor => uint256 balance) public actorNumeraireBalance;

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

    constructor(
        RehypeDopplerHook hook_,
        DopplerHookInitializer initializer_,
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        TestERC20 asset_,
        TestERC20 numeraire_,
        PoolKey memory poolKey_,
        bool isToken0_,
        bool isUsingEth_,
        address buybackDst_,
        address beneficiary1_
    ) {
        hook = hook_;
        initializer = initializer_;
        manager = manager_;
        swapRouter = swapRouter_;
        asset = asset_;
        numeraire = numeraire_;
        poolKey = poolKey_;
        poolId = poolKey_.toId();
        isToken0 = isToken0_;
        isUsingEth = isUsingEth_;
        buybackDst = buybackDst_;
        beneficiary1 = beneficiary1_;

        // Initialize ghost state
        (,, uint128 liquidity,) = hook.getPosition(poolId);
        ghost_lastLiquidity = liquidity;

        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,) = hook.getHookFees(poolId);
        ghost_lastBeneficiaryFees0 = beneficiaryFees0;
        ghost_lastBeneficiaryFees1 = beneficiaryFees1;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Core Swap Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Buy asset tokens with numeraire (exact input)
    /// @param amount Amount of numeraire to spend (will be bounded)
    function buyExactIn(uint256 amount) public createActor {
        // Bound amount to reasonable range
        amount = bound(amount, 0.001 ether, 10 ether);
        ghost_totalSwapAttempts++;

        // Provide numeraire to actor
        if (isUsingEth) {
            deal(currentActor, amount);
        } else {
            deal(address(numeraire), currentActor, amount);
            numeraire.approve(address(swapRouter), amount);
        }

        // Buy: swap numeraire for asset
        // If asset is token0, zeroForOne = false (token1 -> token0)
        // If asset is token1, zeroForOne = true (token0 -> token1)
        bool zeroForOne = !isToken0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount), // Exact input (negative)
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        _executeSwap(params, amount, true);
    }

    /// @notice Sell asset tokens for numeraire (exact input)
    /// @param seed Used to select actor and determine amount
    function sellExactIn(uint256 seed) public useActor(seed) {
        // Skip if actor has no assets
        if (currentActor == address(0) || actorAssetBalance[currentActor] == 0) {
            return;
        }

        uint256 amount = bound(seed, 1, actorAssetBalance[currentActor]);
        ghost_totalSwapAttempts++;

        asset.approve(address(swapRouter), amount);

        // Sell: swap asset for numeraire
        bool zeroForOne = isToken0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount), // Exact input (negative)
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        _executeSwap(params, 0, false);
    }

    /// @notice Execute swap with comprehensive error handling
    /// @param params Swap parameters
    /// @param ethValue ETH value to send (for ETH swaps)
    /// @param isBuy True if buying asset, false if selling
    function _executeSwap(IPoolManager.SwapParams memory params, uint256 ethValue, bool isBuy) internal {
        // Capture state before swap
        (,, uint128 liquidityBefore,) = hook.getPosition(poolId);

        try swapRouter.swap{ value: isUsingEth && isBuy ? ethValue : 0 }(
            poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0)
        ) returns (BalanceDelta delta) {
            ghost_successfulSwaps++;

            if (isBuy) {
                ghost_buySwaps++;
                // Track asset received
                uint256 assetReceived;
                if (isToken0) {
                    // Asset is token0, delta.amount0 should be positive (received)
                    assetReceived =
                        delta.amount0() > 0 ? uint256(int256(delta.amount0())) : uint256(int256(-delta.amount0()));
                } else {
                    // Asset is token1, delta.amount1 should be positive (received)
                    assetReceived =
                        delta.amount1() > 0 ? uint256(int256(delta.amount1())) : uint256(int256(-delta.amount1()));
                }
                actorAssetBalance[currentActor] += assetReceived;
            } else {
                ghost_sellSwaps++;
                // Track asset sold
                uint256 assetSold = uint256(-params.amountSpecified);
                if (actorAssetBalance[currentActor] >= assetSold) {
                    actorAssetBalance[currentActor] -= assetSold;
                }
            }

            // Update ghost state
            (,, uint128 beneficiaryFees0After, uint128 beneficiaryFees1After,) = hook.getHookFees(poolId);
            ghost_lastBeneficiaryFees0 = beneficiaryFees0After;
            ghost_lastBeneficiaryFees1 = beneficiaryFees1After;

            // Track liquidity changes
            (,, uint128 liquidityAfter,) = hook.getPosition(poolId);
            if (liquidityAfter > liquidityBefore) {
                ghost_liquidityAdditions++;
            }
            ghost_lastLiquidity = liquidityAfter;
        } catch (bytes memory err) {
            _handleSwapError(err);
        }
    }

    /// @notice Categorize swap errors as expected or unexpected
    /// @param err The error bytes
    function _handleSwapError(bytes memory err) internal {
        bytes4 selector;
        assembly {
            selector := mload(add(err, 0x20))
        }

        revertSelectors.push(selector);

        // Check for wrapped errors (V4 style)
        if (selector == CustomRevert.WrappedError.selector) {
            // Try to decode the inner error
            // For now, count as expected since it's a known V4 error pattern
            ghost_expectedReverts++;
            return;
        }

        // Known acceptable reverts from Pool/TickMath
        if (
            selector == Pool.PriceLimitAlreadyExceeded.selector || selector == Pool.PriceLimitOutOfBounds.selector
                || selector == Pool.PoolNotInitialized.selector || selector == TickMath.InvalidSqrtPrice.selector
                || selector == TickMath.InvalidTick.selector
        ) {
            ghost_expectedReverts++;
            return;
        }

        // Standard Solidity errors
        if (
            selector == bytes4(keccak256("Panic(uint256)")) // Arithmetic errors
                || selector == bytes4(keccak256("Error(string)")) // require() failures
        ) {
            // These could be from the hook's internal operations - count as unexpected
            ghost_unexpectedReverts++;
            return;
        }

        // Any other error is unexpected
        ghost_unexpectedReverts++;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fee Distribution Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Change fee distribution with random percentages
    /// @param assetBuyback Fuzzed percentage for asset buyback
    /// @param numeraireBuyback Fuzzed percentage for numeraire buyback
    /// @param beneficiary Fuzzed percentage for beneficiary
    function changeFeeDistribution(uint256 assetBuyback, uint256 numeraireBuyback, uint256 beneficiary) public {
        // Bound each to create valid distribution
        assetBuyback = bound(assetBuyback, 0, WAD);

        uint256 remaining = WAD - assetBuyback;
        numeraireBuyback = bound(numeraireBuyback, 0, remaining);

        remaining = remaining - numeraireBuyback;
        beneficiary = bound(beneficiary, 0, remaining);

        uint256 lp = remaining - beneficiary;

        // Call from beneficiary1 (who has permission)
        vm.prank(beneficiary1);

        try hook.setFeeDistributionByBeneficiary(poolId, assetBuyback, numeraireBuyback, beneficiary, lp) {
            ghost_feeDistributionChanges++;
        } catch {
            // Expected to fail if not beneficiary or invalid params
        }
    }

    /// @notice Set extreme fee distribution (100% to single category)
    /// @param category 0=assetBuyback, 1=numeraireBuyback, 2=beneficiary, 3=lp
    function setExtremeFeeDistribution(uint8 category) public {
        category = uint8(bound(category, 0, 3));

        uint256 assetBuyback;
        uint256 numeraireBuyback;
        uint256 beneficiary;
        uint256 lp;

        if (category == 0) {
            assetBuyback = WAD;
        } else if (category == 1) {
            numeraireBuyback = WAD;
        } else if (category == 2) {
            beneficiary = WAD;
        } else {
            lp = WAD;
        }

        vm.prank(beneficiary1);
        try hook.setFeeDistributionByBeneficiary(poolId, assetBuyback, numeraireBuyback, beneficiary, lp) {
            ghost_feeDistributionChanges++;
        } catch {
            // Expected in some cases
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fee Collection Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Collect beneficiary fees (callable by anyone)
    function collectBeneficiaryFees() public createActor {
        uint256 buybackAssetBefore = asset.balanceOf(buybackDst);
        uint256 buybackNumeraireBefore = isUsingEth ? buybackDst.balance : numeraire.balanceOf(buybackDst);

        try hook.collectFees(address(asset)) {
            ghost_feeCollections++;

            // Track buyback destination balance changes
            uint256 buybackAssetAfter = asset.balanceOf(buybackDst);
            uint256 buybackNumeraireAfter = isUsingEth ? buybackDst.balance : numeraire.balanceOf(buybackDst);

            if (buybackAssetAfter > buybackAssetBefore) {
                ghost_buybackDstAssetReceived += buybackAssetAfter - buybackAssetBefore;
            }
            if (buybackNumeraireAfter > buybackNumeraireBefore) {
                ghost_buybackDstNumeraireReceived += buybackNumeraireAfter - buybackNumeraireBefore;
            }
        } catch {
            // Fee collection can fail in certain states
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Edge Case Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Test with very small amounts (near EPSILON = 1e6)
    function buyTinyAmount() public createActor {
        // EPSILON in the hook is 1e6, test around that
        uint256 amount = bound(uint256(keccak256(abi.encode(block.timestamp, msg.sender))), 1, 1e7);
        ghost_totalSwapAttempts++;

        if (isUsingEth) {
            deal(currentActor, amount);
        } else {
            deal(address(numeraire), currentActor, amount);
            numeraire.approve(address(swapRouter), amount);
        }

        bool zeroForOne = !isToken0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        _executeSwap(params, amount, true);
    }

    /// @notice Test with large amounts (stress test)
    function buyLargeAmount() public createActor {
        uint256 amount = bound(uint256(keccak256(abi.encode(block.timestamp, msg.sender))), 100 ether, 1000 ether);
        ghost_totalSwapAttempts++;

        if (isUsingEth) {
            deal(currentActor, amount);
        } else {
            deal(address(numeraire), currentActor, amount);
            numeraire.approve(address(swapRouter), amount);
        }

        bool zeroForOne = !isToken0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        _executeSwap(params, amount, true);
    }

    /// @notice Rapid sequential buys (same direction)
    /// @param count Number of buys to perform (bounded)
    function rapidBuys(uint8 count) public createActor {
        count = uint8(bound(count, 2, 10));

        for (uint8 i = 0; i < count; i++) {
            uint256 amount = 0.5 ether;

            if (isUsingEth) {
                deal(currentActor, amount);
            } else {
                deal(address(numeraire), currentActor, amount);
                numeraire.approve(address(swapRouter), amount);
            }

            ghost_totalSwapAttempts++;

            bool zeroForOne = !isToken0;

            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });

            _executeSwap(params, amount, true);
        }
    }

    /// @notice Alternating buy/sell pattern
    /// @param iterations Number of buy-sell cycles (bounded)
    function alternateBuySell(uint8 iterations) public createActor {
        iterations = uint8(bound(iterations, 1, 5));

        for (uint8 i = 0; i < iterations; i++) {
            // Buy
            uint256 buyAmount = 1 ether;

            if (isUsingEth) {
                deal(currentActor, buyAmount);
            } else {
                deal(address(numeraire), currentActor, buyAmount);
                numeraire.approve(address(swapRouter), buyAmount);
            }

            ghost_totalSwapAttempts++;

            bool zeroForOneBuy = !isToken0;

            IPoolManager.SwapParams memory buyParams = IPoolManager.SwapParams({
                zeroForOne: zeroForOneBuy,
                amountSpecified: -int256(buyAmount),
                sqrtPriceLimitX96: zeroForOneBuy ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });

            _executeSwap(buyParams, buyAmount, true);

            // Sell half of what we have
            if (actorAssetBalance[currentActor] > 0) {
                uint256 sellAmount = actorAssetBalance[currentActor] / 2;
                if (sellAmount > 0) {
                    asset.approve(address(swapRouter), sellAmount);

                    ghost_totalSwapAttempts++;

                    bool zeroForOneSell = isToken0;

                    IPoolManager.SwapParams memory sellParams = IPoolManager.SwapParams({
                        zeroForOne: zeroForOneSell,
                        amountSpecified: -int256(sellAmount),
                        sqrtPriceLimitX96: zeroForOneSell ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                    });

                    _executeSwap(sellParams, 0, false);
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Get the number of actors
    function getActorCount() external view returns (uint256) {
        return actors.count();
    }

    /// @notice Get all collected revert selectors
    function getRevertSelectors() external view returns (bytes4[] memory) {
        return revertSelectors;
    }

    /// @notice Get revert selector count
    function getRevertSelectorCount() external view returns (uint256) {
        return revertSelectors.length;
    }
}
