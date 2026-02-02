// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { IBundleCallback, CreateResult, Transfer, Call } from "src/interfaces/IBundleCallback.sol";

/// @notice Test callback that returns empty lists
contract EmptyCallback is IBundleCallback {
    function plan(CreateResult calldata, bytes calldata) 
        external 
        pure 
        returns (Transfer[] memory transfers, Call[] memory calls) 
    {
        // Return empty arrays - this should work fine in bundler
        return (new Transfer[](0), new Call[](0));
    }
}

/// @notice Test to verify empty callback behavior
contract BundlerEmptyCallbackTest is Test {
    EmptyCallback emptyCallback;
    
    function setUp() public {
        emptyCallback = new EmptyCallback();
    }
    
    function test_emptyCallback_ReturnsEmptyArrays() public {
        // Create dummy CreateResult
        CreateResult memory result = CreateResult({
            asset: address(0x1234),
            pool: address(0x5678),
            governance: address(0x9ABC),
            timelock: address(0xDEF0),
            migrationPool: address(0x1111)
        });
        
        // Call plan with empty callback data
        (Transfer[] memory transfers, Call[] memory calls) = emptyCallback.plan(result, "");
        
        // Verify both arrays are empty
        assertEq(transfers.length, 0);
        assertEq(calls.length, 0);
    }
    
    function test_emptyCallback_CanBeCalledMultipleTimes() public {
        CreateResult memory result = CreateResult({
            asset: address(0x1234),
            pool: address(0x5678),
            governance: address(0x9ABC),
            timelock: address(0xDEF0),
            migrationPool: address(0x1111)
        });
        
        // Call multiple times - should always return empty
        for (uint256 i = 0; i < 5; i++) {
            (Transfer[] memory transfers, Call[] memory calls) = emptyCallback.plan(result, "");
            assertEq(transfers.length, 0);
            assertEq(calls.length, 0);
        }
    }
}
