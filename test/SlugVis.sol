pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {SlugData} from "../src/Doppler.sol";

struct SlugDataWithName {
    string name;
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
}

library SlugVis {
    function visualizeSlugs(
        uint256 timestamp,
        SlugData memory lowerSlug,
        SlugData memory upperSlug,
        SlugData memory pdSlug
    ) public pure {
        string memory json;
        SlugDataWithName[] memory slugs = checkSlugsAndCreatedNamedSlugArray(lowerSlug, upperSlug, pdSlug);
        json = _constructJson(timestamp, slugs);
        console2.log(json);
    }

    function checkSlugsAndCreatedNamedSlugArray(
        SlugData memory lowerSlug,
        SlugData memory upperSlug,
        SlugData memory pdSlug
    ) internal pure returns (SlugDataWithName[] memory) {
        bool lowerSlugExists = lowerSlug.liquidity > 0;
        bool upperSlugExists = upperSlug.liquidity > 0;
        bool pdSlugExists = pdSlug.liquidity > 0;

        uint256 numSlugs = (lowerSlugExists ? 1 : 0) + (upperSlugExists ? 1 : 0) + (pdSlugExists ? 1 : 0);

        SlugDataWithName[] memory namedSlugs = new SlugDataWithName[](numSlugs);
        uint256 index = 0;

        if (lowerSlugExists) {
            namedSlugs[index++] =
                SlugDataWithName("lowerSlug", lowerSlug.liquidity, lowerSlug.tickLower, lowerSlug.tickUpper);
        }
        if (upperSlugExists) {
            namedSlugs[index++] =
                SlugDataWithName("upperSlug", upperSlug.liquidity, upperSlug.tickLower, upperSlug.tickUpper);
        }
        if (pdSlugExists) {
            namedSlugs[index] = SlugDataWithName("pdSlug", pdSlug.liquidity, pdSlug.tickLower, pdSlug.tickUpper);
        }

        return namedSlugs;
    }

    function _constructJson(uint256 timestamp, SlugDataWithName[] memory slugs) internal pure returns (string memory) {
        string memory json = "{ \"data\": [";

        for (uint256 i = 0; i < slugs.length; i++) {
            json = string(
                abi.encodePacked(
                    json,
                    "{",
                    "\"slugName\": \"",
                    slugs[i].name,
                    "\",",
                    "\"timestamp\": ",
                    uint2str(timestamp),
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

            if (i < slugs.length - 1) {
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
