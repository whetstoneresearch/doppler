// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

/// @title MockQuoter
/// @notice Mock quoter contract for testing _rebalanceFees and _simulateSwap
/// @dev Supports keyed responses. quoteSingle is view-compatible.
/// @dev NOTE: Call tracking removed because quoteSingle must be view (called from view context)
contract MockQuoter {
    // ═══════════════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════════════

    struct QuoteResponse {
        int256 amount0;
        int256 amount1;
        uint160 sqrtPriceAfterX96;
        bool shouldRevert;
        bytes revertData;
    }

    struct RecordedCall {
        bool zeroForOne;
        int256 amountSpecified;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Default response for unregistered queries
    QuoteResponse public defaultResponse;

    /// @notice Responses keyed by hash of (zeroForOne, amountSpecified)
    mapping(bytes32 => QuoteResponse) internal _responses;

    /// @notice Whether a specific response has been set (to distinguish from empty response)
    mapping(bytes32 => bool) internal _responseSet;

    /// @notice Call counter for verification (only updated in non-view functions)
    uint256 public callCount;

    /// @notice Recorded calls for verification (only updated in non-view functions)
    RecordedCall[] internal _recordedCalls;

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Set response for specific (zeroForOne, amountSpecified) combination
    /// @param zeroForOne Direction of the swap
    /// @param amountSpecified Amount specified for the swap (negative = exact input)
    /// @param response The response to return for this query
    function setResponse(bool zeroForOne, int256 amountSpecified, QuoteResponse memory response) external {
        bytes32 key = _responseKey(zeroForOne, amountSpecified);
        _responses[key] = response;
        _responseSet[key] = true;
    }

    /// @notice Set default response for unregistered queries
    /// @param response The default response
    function setDefaultResponse(QuoteResponse memory response) external {
        defaultResponse = response;
    }

    /// @notice Reset all state
    function reset() external {
        callCount = 0;
        delete _recordedCalls;
        defaultResponse = QuoteResponse({
            amount0: 0,
            amount1: 0,
            sqrtPriceAfterX96: 0,
            shouldRevert: false,
            revertData: ""
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // QUOTER INTERFACE
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Mock implementation of quoteSingle (view-compatible)
    /// @dev Cannot track calls here because this is called from view context
    /// @param params The swap parameters
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    /// @return sqrtPriceAfterX96 The sqrt price after the swap
    /// @return gasUsed Always returns 0 for mock
    function quoteSingle(
        PoolKey calldata,
        IPoolManager.SwapParams calldata params
    ) external view returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 gasUsed) {
        QuoteResponse memory response;

        bytes32 key = _responseKey(params.zeroForOne, params.amountSpecified);
        
        if (_responseSet[key]) {
            response = _responses[key];
        } else {
            response = defaultResponse;
        }

        if (response.shouldRevert) {
            if (response.revertData.length > 0) {
                bytes memory revertData = response.revertData;
                assembly {
                    revert(add(revertData, 32), mload(revertData))
                }
            }
            revert("MockQuoter: configured to revert");
        }

        return (response.amount0, response.amount1, response.sqrtPriceAfterX96, 0);
    }

    /// @notice Non-view version of quoteSingle that tracks calls (for tests that need call tracking)
    /// @dev Use this when you need to verify call counts, but not from view context
    function quoteSingleWithTracking(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 gasUsed) {
        callCount++;
        _recordedCalls.push(RecordedCall({ zeroForOne: params.zeroForOne, amountSpecified: params.amountSpecified }));
        
        // Call the view version for the actual response
        return this.quoteSingle(key, params);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // VERIFICATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Get number of times quoteSingleWithTracking was called
    function getCallCount() external view returns (uint256) {
        return callCount;
    }

    /// @notice Get recorded call at index (0-indexed)
    function getRecordedCall(uint256 index) external view returns (RecordedCall memory) {
        require(index < _recordedCalls.length, "Index out of bounds");
        return _recordedCalls[index];
    }

    /// @notice Get all recorded calls
    function getAllRecordedCalls() external view returns (RecordedCall[] memory) {
        return _recordedCalls;
    }

    /// @notice Verify quoteSingleWithTracking was called with specific params
    function wasCalledWith(bool zeroForOne, int256 amountSpecified) external view returns (bool) {
        for (uint256 i = 0; i < _recordedCalls.length; i++) {
            if (_recordedCalls[i].zeroForOne == zeroForOne && _recordedCalls[i].amountSpecified == amountSpecified) {
                return true;
            }
        }
        return false;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Calculate response key from parameters
    function _responseKey(bool zeroForOne, int256 amountSpecified) internal pure returns (bytes32) {
        return keccak256(abi.encode(zeroForOne, amountSpecified));
    }
}
