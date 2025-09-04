// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { FullMath } from "@v4-core/libraries/FullMath.sol";

library MigrationMath {
    using FullMath for uint256;
    using FullMath for uint160;

    /**
     * @dev Computes the amounts for an initial Uniswap V2 pool deposit.
     * @param balance0 Current balance of token0
     * @param balance1 Current balance of token1
     * @param sqrtPriceX96 Square root price of the pool as a Q64.96 value
     * @return depositAmount0 Amount of token0 to deposit
     * @return depositAmount1 Amount of token1 to deposit
     */
    function computeDepositAmounts(
        uint256 balance0,
        uint256 balance1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 depositAmount0, uint256 depositAmount1) {
        // Stolen from https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol#L57
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            depositAmount0 = balance1.mulDiv(1 << 192, ratioX192);
            depositAmount1 = balance0.mulDiv(ratioX192, 1 << 192);
        } else {
            uint256 ratioX128 = sqrtPriceX96.mulDiv(sqrtPriceX96, 1 << 64);
            depositAmount0 = balance1.mulDiv(1 << 128, ratioX128);
            depositAmount1 = balance0.mulDiv(ratioX128, 1 << 128);
        }
    }
}
