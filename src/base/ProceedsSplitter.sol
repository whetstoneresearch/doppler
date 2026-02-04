// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { WAD } from "src/types/WAD.sol";

struct SplitConfiguration {
    address recipient;
    bool isToken0; // True if the asset is token0
    uint256 share;
    uint256 donated;
}

/// @dev Maximum share that can be allocated (50%)
uint256 constant MAX_SPLIT_SHARE = 0.5e18;

error InvalidSplitRecipient();

error SplitShareTooHigh(uint256 actual, uint256 maximum);

error InvalidETHAmount();

event Donate(address indexed token0, address indexed token1, uint256 amount);

event DistributeSplit(address indexed token0, address indexed token1, address indexed recipient, uint256 amount);

abstract contract ProceedsSplitter {
    /// @notice Configuration of proceeds split, stored by asset since they are unique
    mapping(address token0 => mapping(address token1 => SplitConfiguration config)) public splitConfigurationOf;

    function donate(address asset, address numeraire, uint256 amount) external payable {
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        SplitConfiguration storage config = splitConfigurationOf[token0][token1];

        if (numeraire == address(0)) {
            require(msg.value == amount, InvalidETHAmount());
        } else {
            SafeTransferLib.safeTransferFrom(numeraire, msg.sender, address(this), amount);
        }

        config.donated += amount;
        emit Donate(token0, token1, amount);
    }

    function _setSplit(address token0, address token1, SplitConfiguration memory config) internal {
        require(config.recipient != address(0), InvalidSplitRecipient());
        require(config.share <= MAX_SPLIT_SHARE, SplitShareTooHigh(config.share, MAX_SPLIT_SHARE));
        splitConfigurationOf[token0][token1] = config;
    }

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

        if (config.donated > 0) splitAmount += config.donated;
        if (splitAmount == 0) return (balance0, balance1);

        emit DistributeSplit(token0, token1, config.recipient, splitAmount);

        if (numeraire == address(0)) {
            SafeTransferLib.safeTransferETH(config.recipient, splitAmount);
        } else {
            SafeTransferLib.safeTransfer(numeraire, config.recipient, splitAmount);
        }
    }
}
