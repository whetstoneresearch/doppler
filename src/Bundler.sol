// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { Airlock, CreateParams } from "src/Airlock.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";

/// @dev Thrown when an invalid address is passed as a contructor parameter
error InvalidAddresses();

/// @dev Thrown when the asset address doesn't match the predicted one
error InvalidOutputToken();

/**
 * @author Whetstone
 * @custom:security-contact security@whetstone.cc
 */
contract Bundler {
    /// @notice Address of the Airlock contract
    Airlock public immutable airlock;

    /// @notice Address of the Universal Router contract
    UniversalRouter public immutable router;

    /// @notice Address of the QuoterV2 contract
    IQuoterV2 public immutable quoter;

    /**
     * @param airlock_ Immutable address of the Airlock contract
     * @param router_ Immutable address of the Universal Router contract
     * @param quoter_ Immutable address of the QuoterV2 contract
     */
    constructor(Airlock airlock_, UniversalRouter router_, IQuoterV2 quoter_) {
        if (address(airlock_) == address(0) || address(router_) == address(0) || address(quoter_) == address(0)) {
            revert InvalidAddresses();
        }

        airlock = Airlock(airlock_);
        router = UniversalRouter(router_);
        quoter = IQuoterV2(quoter_);
    }

    /**
     * @notice Simulates a bundle operation with an exact output amount
     * @param createData Creation data to pass to the Airlock contract
     * @param params Exact output parameters to pass to the QuoterV2 contract
     * @return amountIn Amount of input token required to receive the exact output amount
     */
    function simulateBundleExactOut(
        CreateParams calldata createData,
        IQuoterV2.QuoteExactOutputSingleParams calldata params
    ) external returns (uint256 amountIn) {
        (address asset,,,,) = airlock.create(createData);
        if (asset != params.tokenOut) {
            revert InvalidOutputToken();
        }
        (amountIn,,,) = quoter.quoteExactOutputSingle(params);
    }

    /**
     * @notice Simulates a bundle operation with an exact input amount
     * @param createData Creation data to pass to the Airlock contract
     * @param params Exact input parameters to pass to the QuoterV2 contract
     * @return amountOut Amount of output token received from the exact input amount
     */
    function simulateBundleExactIn(
        CreateParams calldata createData,
        IQuoterV2.QuoteExactInputSingleParams calldata params
    ) external returns (uint256 amountOut) {
        (address asset,,,,) = airlock.create(createData);
        if (asset != params.tokenOut) {
            revert InvalidOutputToken();
        }
        (amountOut,,,) = quoter.quoteExactInputSingle(params);
    }

    /**
     * @notice Bundles the creation of an asset via the Airlock contract and a buy operation via the Universal Router
     * @param createData Creation data to pass to the Airlock contract
     * @param commands Encoded commands for the Universal Router
     * @param inputs Encoded inputs for the Universal Router
     */
    function bundle(
        CreateParams calldata createData,
        bytes calldata commands,
        bytes[] calldata inputs
    ) external payable {
        (address asset,,,,) = airlock.create(createData);
        uint256 balance = address(this).balance;
        router.execute{ value: balance }(commands, inputs);

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) SafeTransferLib.safeTransferETH(msg.sender, ethBalance);

        uint256 assetBalance = SafeTransferLib.balanceOf(asset, address(this));
        if (assetBalance > 0) SafeTransferLib.safeTransfer(asset, msg.sender, assetBalance);

        uint256 numeraireBalance = SafeTransferLib.balanceOf(createData.numeraire, address(this));
        if (numeraireBalance > 0) SafeTransferLib.safeTransfer(createData.numeraire, msg.sender, numeraireBalance);
    }
}
