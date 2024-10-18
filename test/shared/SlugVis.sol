pragma solidity 0.8.26;

import {console} from "forge-std/console.sol";
import {SlugData, Position} from "../../src/Doppler.sol";

struct SlugDataWithName {
    string name;
    uint128 liquidity;
    int24 tickLower;
    int24 tickUpper;
}

bytes32 constant LOWER_SLUG_SALT = bytes32(uint256(1));
bytes32 constant UPPER_SLUG_SALT = bytes32(uint256(2));
bytes32 constant DISCOVERY_SLUG_SALT = bytes32(uint256(3));

library SlugVis {
    function visualizeSlugs(
        uint256 numPDSlugs,
        uint256 timestamp,
        int24 currentTick,
        function (bytes32) view external returns (Position memory) fx
    ) public view {
        string memory json;
        (SlugData memory lowerSlug, SlugData memory upperSlug, SlugData[] memory pdSlugs) =
            getSlugDataFromPositions(numPDSlugs, fx);
        SlugDataWithName[] memory slugs = checkSlugsAndCreateNamedSlugArray(numPDSlugs, lowerSlug, upperSlug, pdSlugs);
        json = _constructJson(currentTick, timestamp, slugs);
        console.log(json);
    }

    function checkSlugsAndCreateNamedSlugArray(
        uint256 numPDSlugs,
        SlugData memory lowerSlug,
        SlugData memory upperSlug,
        SlugData[] memory pdSlugs
    ) internal pure returns (SlugDataWithName[] memory) {
        bool lowerSlugExists = lowerSlug.liquidity > 0;
        bool upperSlugExists = upperSlug.liquidity > 0;
        uint256 numPdSlugs = 0;

        for (uint256 i = 0; i < numPDSlugs; i++) {
            pdSlugs[i].liquidity > 0 ? numPdSlugs++ : numPdSlugs;
            i++;
        }

        uint256 numSlugs = (lowerSlugExists ? 1 : 0) + (upperSlugExists ? 1 : 0) + numPdSlugs;

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
        // for (uint256 i = 0; i < hook.numPDSlugs(); i++) {
        if (numPdSlugs > 0) {
            for (uint256 i = 0; i < numPdSlugs; i++) {
                namedSlugs[index++] = SlugDataWithName(
                    string(abi.encodePacked("pdSlug", i)),
                    pdSlugs[i].liquidity,
                    pdSlugs[i].tickLower,
                    pdSlugs[i].tickUpper
                );
            }
        }

        return namedSlugs;
    }

    function getSlugDataFromPositions(uint256 numPDSlugs, function (bytes32) view external returns (Position memory) fx)
        internal
        view
        returns (SlugData memory, SlugData memory, SlugData[] memory)
    {
        Position memory lowerPosition = fx(LOWER_SLUG_SALT);
        Position memory upperPosition = fx(UPPER_SLUG_SALT);
        Position[] memory pdPositions = new Position[](numPDSlugs);
        for (uint256 i = 0; i < numPDSlugs; i++) {
            pdPositions[i] = fx(bytes32(uint256(i + 3)));
        }

        SlugData memory lowerSlug = SlugData({
            liquidity: lowerPosition.liquidity,
            tickLower: lowerPosition.tickLower,
            tickUpper: lowerPosition.tickUpper
        });
        SlugData memory upperSlug = SlugData({
            liquidity: upperPosition.liquidity,
            tickLower: upperPosition.tickLower,
            tickUpper: upperPosition.tickUpper
        });
        SlugData[] memory pdSlugs = new SlugData[](numPDSlugs);
        for (uint256 i = 0; i < numPDSlugs; i++) {
            pdSlugs[i] = SlugData({
                liquidity: pdPositions[i].liquidity,
                tickLower: pdPositions[i].tickLower,
                tickUpper: pdPositions[i].tickUpper
            });
        }
        return (lowerSlug, upperSlug, pdSlugs);
    }

    function _constructJson(int24 currentTick, uint256 timestamp, SlugDataWithName[] memory slugs)
        internal
        pure
        returns (string memory)
    {
        string memory json = "{ \"data\": [";

        for (uint256 i = 0; i < slugs.length; i++) {
            json = string(
                abi.encodePacked(
                    json,
                    "{",
                    "\"currentTick\": ",
                    int2str(currentTick),
                    ",",
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
