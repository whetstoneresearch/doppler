// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { Airlock, CreateParams } from "src/Airlock.sol";

error InvalidBundleData();

/**
 * @author Whetstone
 * @custom:security-contact security@whetstone.cc
 */
contract Bundler {
    /**
     * @notice Bundles the creation of an asset via the Airlock contract and a buy operation via a router
     * @param airlock Address of the Airlock contract
     * @param createData Creation data to pass to the Airlock contract
     * @param router Address of the router to use for the buy operation
     * @param routerData Arbitrary data to pass to the router
     */
    function bundle(
        Airlock airlock,
        CreateParams calldata createData,
        address router,
        bytes calldata routerData
    ) external payable {
        if (address(airlock) == address(0) || address(router) == address(0) || routerData.length == 0) {
            revert InvalidBundleData();
        }

        (address asset,,,,) = airlock.create(createData);
        (bool success, bytes memory result) = router.call{ value: msg.value }(routerData);

        if (!success) {
            if (result.length == 0) revert();
            assembly {
                revert(add(32, result), mload(result))
            }
        }

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) SafeTransferLib.safeTransferETH(msg.sender, ethBalance);

        uint256 assetBalance = SafeTransferLib.balanceOf(asset, address(this));
        if (assetBalance > 0) SafeTransferLib.safeTransfer(asset, msg.sender, assetBalance);

        uint256 numeraireBalance = SafeTransferLib.balanceOf(createData.numeraire, address(this));
        if (numeraireBalance > 0) SafeTransferLib.safeTransfer(createData.numeraire, msg.sender, numeraireBalance);
    }
}
