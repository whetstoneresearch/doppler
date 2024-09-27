// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ITokenFactory {
    function create(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address recipient,
        address owner,
        bytes memory tokenData
    ) external returns (address);
}
