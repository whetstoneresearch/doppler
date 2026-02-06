// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { Airlock } from "src/Airlock.sol";

/**
 * @notice
 * @param amount Amount of the top-up (in numeraire)
 * @param isToken0 True if the token0 is the asset token
 */
struct TopUpData {
    uint256 amount;
    bool isToken0;
}

/**
 * @notice Emitted when a top-up is made for an asset / numeraire pair
 * @param sender Address of the sender of the top-up
 * @param asset Address of the asset token
 * @param numeraire Address of the numeraire token (address zero for ETH)
 * @param amount Amount of the top-up (in numeraire)
 */
event TopUp(address indexed sender, address indexed asset, address indexed numeraire, uint256 amount);

/**
 * @notice Emitted when the top-ups for an asset / numeraire pair are pulled up by a migrator
 * @param migrator Address of the migrator pulling up the top-ups
 * @param asset Address of the asset token
 * @param numeraire Address of the numeraire token (address zero for ETH)
 * @param recipient Address of the recipient of the top-ups
 * @param amount Amount of the top-ups pulled up (in numeraire)
 */
event PullUp(
    address indexed migrator, address indexed asset, address indexed numeraire, address recipient, uint256 amount
);

/// @notice Thrown when the sender is not allowed to pull up the top-ups
error SenderCannotPullUp();

/// @notice Thrown when the sender is not the Airlock owner
error SenderNotAirlockOwner();

/// @notice Thrown when the ETH amount sent does not match the specified amount
error InvalidETHAmount();

/**
 * @title TopUpDistributor
 * @author Whetstone Research
 * @notice Receives top-ups (in numeraire) for asset / numeraire pairs and transfers the funds to a recipient
 * when the Airlock migration occurs
 * @custom:security-contact security@whetstone.cc
 */
contract TopUpDistributor {
    /// @notice Address of the Airlock contract
    Airlock public immutable AIRLOCK;

    /// @notice Top-ups data, stored by asset / numeraire pair in ascending order (token0 < token1)
    mapping(address token0 => mapping(address token1 => TopUpData)) public topUpOf;

    /// @notice Returns true if a migrator is allowed to pull up the top-ups
    mapping(address migrator => bool) public canPullUp;

    /// @param airlock Address of the Airlock contract
    constructor(address airlock) {
        AIRLOCK = Airlock(payable(airlock));
    }

    /**
     * @notice Enables (or disables) a migrator to pull up the top-ups
     * @param migrator Address of the migrator
     * @param canPull Whether the migrator can pull up the top-ups or not
     */
    function setPullUp(address migrator, bool canPull) external {
        if (msg.sender != AIRLOCK.owner()) revert SenderNotAirlockOwner();
        canPullUp[migrator] = canPull;
    }

    /**
     * @notice Tops up the amount for a given asset / numeraire pair (only the numeraire is accepted)
     * @param asset Address of the asset
     * @param numeraire Address of the numeraire (pass address zero for ETH)
     * @param amount Amount to top up (in numeraire)
     */
    function topUp(address asset, address numeraire, uint256 amount) external payable {
        (address token0, address token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);

        TopUpData storage config = topUpOf[token0][token1];
        config.isToken0 = asset < numeraire;

        if (numeraire == address(0)) {
            require(msg.value == amount, InvalidETHAmount());
        } else {
            require(msg.value == 0, InvalidETHAmount());
            SafeTransferLib.safeTransferFrom(numeraire, msg.sender, address(this), amount);
        }

        config.amount += amount;
        emit TopUp(msg.sender, asset, numeraire, amount);
    }

    /**
     * @notice Pulls up the top-ups for a given asset / numeraire pair and sends them to the recipient
     * @dev Only callable by an approved migrator
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param recipient Recipient of the top-ups
     */
    function pullUp(address token0, address token1, address recipient) external {
        require(canPullUp[msg.sender], SenderCannotPullUp());

        TopUpData storage config = topUpOf[token0][token1];

        uint256 amountToPullUp = config.amount;
        if (amountToPullUp == 0) return;
        config.amount = 0;

        address numeraire = config.isToken0 ? token1 : token0;

        if (numeraire == address(0)) {
            SafeTransferLib.safeTransferETH(recipient, amountToPullUp);
        } else {
            SafeTransferLib.safeTransfer(numeraire, recipient, amountToPullUp);
        }

        emit PullUp(msg.sender, config.isToken0 ? token0 : token1, numeraire, recipient, amountToPullUp);
    }
}
