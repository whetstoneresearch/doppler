pragma solidity 0.8.26;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";

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
}