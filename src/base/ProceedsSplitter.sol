// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { TopUpDistributor } from "src/TopUpDistributor.sol";
import { WAD } from "src/types/WAD.sol";

/**
 * @notice Configuration of the proceeds split for an asset / numeraire pair
 * @param recipient Address of the recipient of the split
 * @param isToken0 True if the asset is token0, false otherwise
 * @param share Share of the split to allocate to the recipient (in WAD)
 */
struct SplitConfiguration {
    address recipient;
    bool isToken0;
    uint256 share;
}

/// @dev Maximum share that can be allocated (50%)
uint256 constant MAX_SPLIT_SHARE = 0.5e18;

/// @notice Thrown when the recipient of the split is the zero address
error InvalidSplitRecipient();

/// @notice Thrown when the share of the split is higher than the maximum allowed
error SplitShareTooHigh(uint256 actual, uint256 maximum);

/**
 * @notice Emitted when the proceeds split is distributed for an asset / numeraire pair
 * @param token0 Address of token0 of the pair
 * @param token1 Address of token1 of the pair
 * @param recipient Address of the recipient of the split
 * @param amount Amount of the split distributed (in numeraire)
 */
event DistributeSplit(address indexed token0, address indexed token1, address indexed recipient, uint256 amount);

/**
 * @title ProceedsSplitter base contract
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @dev Base contract to be inherited by the migrators to implement the proceeds split logic
 */
abstract contract ProceedsSplitter {
    /// @notice Address of the TopUpDistributor contract
    TopUpDistributor public immutable TOP_UP_DISTRIBUTOR;

    /// @notice Configuration of proceeds split, stored by asset since they are unique
    mapping(address token0 => mapping(address token1 => SplitConfiguration config)) public splitConfigurationOf;

    /// @param topUpDistributor Address of the TopUpDistributor contract
    constructor(TopUpDistributor topUpDistributor) {
        TOP_UP_DISTRIBUTOR = topUpDistributor;
    }

    /**
     * @dev Sets the proceeds split configuration for an asset / numeraire pair, ordered in ascending
     * order (token0 < token1)
     * @param token0 Address of token0 of the pair
     * @param token1 Address of token1 of the pair
     * @param config Split configuration to set for the pair
     */
    function _setSplit(address token0, address token1, SplitConfiguration memory config) internal {
        require(config.recipient != address(0), InvalidSplitRecipient());
        require(config.share <= MAX_SPLIT_SHARE, SplitShareTooHigh(config.share, MAX_SPLIT_SHARE));
        splitConfigurationOf[token0][token1] = config;
    }

    /**
     * @dev Distributes the proceeds split for an asset / numeraire pair, ordered in ascending
     * order (token0 < token1), note that only the numeraire balance is split and transferred
     * @param token0 Address of token0 of the pair
     * @param token1 Address of token1 of the pair
     * @param balance0 Balance of token0 to split
     * @param balance1 Balance of token1 to split
     * @return balanceLeft0 Balance of token0 left after the split
     * @return balanceLeft1 Balance of token1 left after the split
     */
    function _distributeSplit(
        address token0,
        address token1,
        uint256 balance0,
        uint256 balance1
    ) internal returns (uint256 balanceLeft0, uint256 balanceLeft1) {
        SplitConfiguration memory config = splitConfigurationOf[token0][token1];

        balanceLeft0 = balance0;
        balanceLeft1 = balance1;

        address numeraire;
        uint256 splitAmount;

        // We use the canonical nomenclature, `isToken0` refers to asset being token0
        if (config.isToken0) {
            numeraire = token1;
            splitAmount = balance1 * config.share / WAD;
            balanceLeft1 = balance1 - splitAmount;
        } else {
            numeraire = token0;
            splitAmount = balance0 * config.share / WAD;
            balanceLeft0 = balance0 - splitAmount;
        }

        TOP_UP_DISTRIBUTOR.pullUp(token0, token1, config.recipient);
        if (splitAmount == 0) return (balance0, balance1);

        emit DistributeSplit(token0, token1, config.recipient, splitAmount);

        if (numeraire == address(0)) {
            SafeTransferLib.safeTransferETH(config.recipient, splitAmount);
        } else {
            SafeTransferLib.safeTransfer(numeraire, config.recipient, splitAmount);
        }
    }
}
