pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {Doppler, SlugData} from "../src/Doppler.sol";
import {DopplerImplementation} from "./DopplerImplementation.sol";
import {BaseTest} from "./BaseTest.sol";

library SlugVis {
    using PoolIdLibrary for PoolKey;

    function visualizeSlugs(
        uint256 timestamp,
        SlugData memory lowerSlug,
        SlugData memory upperSlug,
        SlugData memory pdSlug
    ) public pure {
        string[] memory slugNames = new string[](3);
        slugNames[0] = "lowerSlug";
        slugNames[1] = "upperSlug";
        slugNames[2] = "pdSlug";

        SlugData[] memory slugs = new SlugData[](3);
        slugs[0] = lowerSlug;
        slugs[1] = upperSlug;
        slugs[2] = pdSlug;
        uint256[] memory timestamps = new uint256[](3);
        timestamps[0] = timestamp;
        timestamps[1] = timestamp;
        timestamps[2] = timestamp;

        string memory json = _constructJson(timestamps, slugs, slugNames);

        console2.log(json);
    }

    function _constructJson(uint256[] memory timestamps, SlugData[] memory slugs, string[] memory slugNames)
        internal
        pure
        returns (string memory)
    {
        string memory json = "{ \"data\": [";

        for (uint256 i = 0; i < timestamps.length; i++) {
            json = string(
                abi.encodePacked(
                    json,
                    "{",
                    "\"slugName\": \"",
                    slugNames[i],
                    "\",",
                    "\"timestamp\": ",
                    uint2str(timestamps[i]),
                    ",",
                    "\"tickLower\": ",
                    int2str(slugs[i].tickLower),
                    ",",
                    "\"tickUpper\": ",
                    int2str(slugs[i].tickUpper),
                    ",",
                    "\"liquidity\": ",
                    uint2str(slugs[i].liquidity),
                    "}"
                )
            );

            if (i < timestamps.length - 1) {
                json = string(abi.encodePacked(json, ","));
            }
        }

        json = string(abi.encodePacked(json, "] }"));
        return json;
    }

    function uint2str(uint256 _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        return string(bstr);
    }

    function int2str(int256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        bool negative = _i < 0;
        uint256 i = uint256(negative ? -_i : _i);
        uint256 j = i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        if (negative) {
            length++; // Make room for '-' sign
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (i != 0) {
            bstr[--k] = bytes1(uint8(48 + i % 10));
            i /= 10;
        }
        if (negative) {
            bstr[0] = "-";
        }
        return string(bstr);
    }
}
