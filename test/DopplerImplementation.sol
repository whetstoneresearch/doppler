pragma solidity 0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Doppler} from "../src/Doppler.sol";

contract DopplerImplementation is Doppler {
    constructor(
        address _poolManager,
        uint256 _numTokensToSell,
        uint256 _startingTime,
        uint256 _endingTime,
        int24 _startingTick,
        int24 _endingTick,
        uint256 _epochLength,
        uint256 _gamma,
        bool _isToken0,
        IHooks addressToEtch
    )
        Doppler(
            IPoolManager(_poolManager),
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

    function getExpectedAmountSold() public view returns (uint256) {
        return _getExpectedAmountSold();
    }

    function getMaxTickDeltaPerEpoch() public view returns (int256) {
        return _getMaxTickDeltaPerEpoch();
    }
}
