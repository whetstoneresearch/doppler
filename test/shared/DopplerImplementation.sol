pragma solidity 0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Doppler, SlugData, Position} from "../../src/Doppler.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

contract DopplerImplementation is Doppler {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    constructor(
        address _poolManager,
        PoolKey memory _poolKey,
        uint256 _numTokensToSell,
        uint256 _startingTime,
        uint256 _endingTime,
        int24 _startingTick,
        int24 _endingTick,
        uint256 _epochLength,
        int24 _gamma,
        bool _isToken0,
        IHooks addressToEtch
    )
        Doppler(
            IPoolManager(_poolManager),
            _poolKey,
            _numTokensToSell,
            _startingTime,
            _endingTime,
            _startingTick,
            _endingTick,
            _epochLength,
            _gamma,
            _isToken0
        )
    {
        Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}

    function getStartingTime() public view returns (uint256) {
        return startingTime;
    }

    function getEndingTime() public view returns (uint256) {
        return endingTime;
    }

    function getEpochLength() public view returns (uint256) {
        return epochLength;
    }

    function getIsToken0() public view returns (bool) {
        return isToken0;
    }

    function getNumTokensToSell() public view returns (uint256) {
        return numTokensToSell;
    }

    function getStartingTick() public view returns (int24) {
        return startingTick;
    }

    function getEndingTick() public view returns (int24) {
        return endingTick;
    }

    function getGamma() public view returns (int24) {
        return gamma;
    }

    function getExpectedAmountSold(uint256 timestamp) public view returns (uint256) {
        return _getExpectedAmountSold(timestamp);
    }

    function getMaxTickDeltaPerEpoch() public view returns (int256) {
        return _getMaxTickDeltaPerEpoch();
    }

    function getElapsedGamma() public view returns (int256) {
        return _getElapsedGamma();
    }

    function getTicksBasedOnState(int256 accumulator, int24 tickSpacing) public view returns (int24, int24) {
        return _getTicksBasedOnState(accumulator, tickSpacing);
    }

    function getCurrentEpoch() public view returns (uint256) {
        return _getCurrentEpoch();
    }

    function getNormalizedTimeElapsed(uint256 timestamp) public view returns (uint256) {
        return _getNormalizedTimeElapsed(timestamp);
    }

    function getGammaShare() public view returns (int256) {
        return _getGammaShare();
    }

    function getEpochEndWithOffset(uint256 offset) public view returns (uint256) {
        return _getEpochEndWithOffset(offset);
    }

    function computeLowerSlugData(
        PoolKey memory key,
        uint256 requiredProceeds,
        uint256 totalProceeds,
        uint256 totalTokensSold,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceNext
    ) public view returns (SlugData memory) {
        return
            _computeLowerSlugData(key, requiredProceeds, totalProceeds, totalTokensSold, sqrtPriceLower, sqrtPriceNext);
    }

    function computeUpperSlugData(PoolKey memory poolKey, uint256 totalTokensSold, int24 currentTick)
        public
        view
        returns (SlugData memory)
    {
        return _computeUpperSlugData(poolKey, totalTokensSold, currentTick);
    }

    function computePriceDiscoverySlugData(PoolKey memory poolKey, SlugData memory upperSlug, int24 tickUpper)
        public
        view
        returns (SlugData memory)
    {
        return _computePriceDiscoverySlugData(poolKey, upperSlug, tickUpper);
    }

    function getPositions(bytes32 salt) public view returns (Position memory) {
        return positions[salt];
    }

    function unlock(bytes memory data) public returns (bytes memory) {
        return poolManager.unlock(data);
    }

    function getCurrentTick(PoolId poolId) public view returns (int24) {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        return currentTick;
    }

    function getRequiredProceeds(uint160 sqrtPriceLower, uint160 sqrtPriceUpper, uint256 totalTokensSold)
        public
        view
        returns (uint256)
    {
        return _computeRequiredProceeds(sqrtPriceLower, sqrtPriceUpper, totalTokensSold);
    }
}
