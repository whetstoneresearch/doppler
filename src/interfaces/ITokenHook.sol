// SPDX-License-Identifier: GPL
pragma solidity ^0.8.13;

interface ITokenHook {
    function onMigration(address asset, bytes calldata data) external;

    function onSwap(
        bytes calldata data
    ) external;

    function onHookInitialization(address asset, bytes calldata data) external;
}
