// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ITokenFactory {
    function create(bytes memory tokenData) external returns (address);
}
