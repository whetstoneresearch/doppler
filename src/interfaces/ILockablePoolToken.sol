// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILockablePoolToken {
    function lockPool(address pool) external;
    function unlockPool() external;
}
