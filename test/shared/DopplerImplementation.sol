// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";
import { Doppler, SlugData, Position } from "src/Doppler.sol";

contract DopplerImplementation is Doppler {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    constructor(
        address _poolManager,
        uint256 _numTokensToSell,
        uint256 _minimumProceeds,
        uint256 _maximumProceeds,
        uint256 _startingTime,
        uint256 _endingTime,
        int24 _startingTick,
        int24 _endingTick,
        uint256 _epochLength,
        int24 _gamma,
        bool _isToken0,
        uint256 _numPDSlugs,
        address initializer_,
        uint24 lpFee_,
        IHooks addressToEtch
    )
        Doppler(
            IPoolManager(_poolManager),
            _numTokensToSell,
            _minimumProceeds,
            _maximumProceeds,
            _startingTime,
            _endingTime,
            _startingTick,
            _endingTick,
            _epochLength,
            _gamma,
            _isToken0,
            _numPDSlugs,
            initializer_,
            lpFee_
        )
    {
        Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    function validateHookAddress(
        BaseHook _this
    ) internal pure override { }

    function resetInitialized() public {
        isInitialized = false;
    }

    function setEarlyExit() public {
        earlyExit = true;
    }

    function getExpectedAmountSoldWithEpochOffset(
        int256 offset
    ) public view returns (uint256) {
        return _getExpectedAmountSoldWithEpochOffset(offset);
    }

    function getMaxTickDeltaPerEpoch() public view returns (int256) {
        return _getMaxTickDeltaPerEpoch();
    }

    function getTicksBasedOnState(int256 accumulator, int24 tickSpacing) public view returns (int24, int24) {
        return _getTicksBasedOnState(accumulator, tickSpacing);
    }

    function getCurrentEpoch() public view returns (uint256) {
        return _getCurrentEpoch();
    }

    function getTotalEpochs() public view returns (uint256) {
        return totalEpochs;
    }

    function getNormalizedTimeElapsed(
        uint256 timestamp
    ) public view returns (uint256) {
        return _getNormalizedTimeElapsed(timestamp);
    }

    function getEpochEndWithOffset(
        uint256 offset
    ) public view returns (uint256) {
        return _getEpochEndWithOffset(offset);
    }

    function getNumPDSlugs() public view returns (uint256) {
        return numPDSlugs;
    }

    function alignComputedTickWithTickSpacing(int24 tick, int24 tickSpacing) public view returns (int24) {
        return _alignComputedTickWithTickSpacing(tick, tickSpacing);
    }

    /*
    function alignTickDeltaWithTickSpacing(int256 tick, int256 tickSpacing) public view returns (int256) {
        return _alignTickDeltaWithTickSpacing(tick, tickSpacing);
    }
    */

    function computeLowerSlugData(
        PoolKey memory key,
        uint256 requiredProceeds,
        uint256 totalProceeds,
        uint256 totalTokensSold,
        int24 tickLower,
        int24 currentTick
    ) public view returns (SlugData memory) {
        return _computeLowerSlugData(key, requiredProceeds, totalProceeds, totalTokensSold, tickLower, currentTick);
    }

    function computeUpperSlugData(
        PoolKey memory poolKey,
        uint256 totalTokensSold,
        int24 currentTick,
        uint256 assetAvailable
    ) public view returns (SlugData memory, uint256 assetRemaining) {
        return _computeUpperSlugData(poolKey, totalTokensSold, currentTick, assetAvailable);
    }

    function computePriceDiscoverySlugsData(
        PoolKey memory poolKey,
        SlugData memory upperSlug,
        int24 tickUpper,
        uint256 assetAvailable
    ) public view returns (SlugData[] memory) {
        return _computePriceDiscoverySlugsData(poolKey, upperSlug, tickUpper, assetAvailable);
    }

    function getPositions(
        bytes32 salt
    ) public view returns (Position memory) {
        return positions[salt];
    }

    function unlock(
        bytes memory data
    ) public returns (bytes memory) {
        return poolManager.unlock(data);
    }

    function getCurrentTick() public view returns (int24) {
        (, int24 currentTick,,) = poolManager.getSlot0(poolKey.toId());
        return currentTick;
    }

    function getRequiredProceeds(
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper,
        uint256 totalTokensSold
    ) public view returns (uint256) {
        return _computeRequiredProceeds(sqrtPriceLower, sqrtPriceUpper, totalTokensSold);
    }

    function getFeesAccrued() public view returns (BalanceDelta) {
        return state.feesAccrued;
    }

    function getTotalProceeds() public view returns (uint256) {
        return state.totalProceeds;
    }

    function getTotalTokensSold() public view returns (uint256) {
        return state.totalTokensSold;
    }
}
