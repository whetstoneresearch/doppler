// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/**
 * @title Token Factory Interface
 * @notice Contracts deploying new asset token must implement this interface.
 */
interface ITokenFactory {
    /**
     * @notice Deploys a new asset token.
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param initialSupply Initial supply that will be minted
     * @param recipient Address receiving the initial supply
     * @param owner Address receiving the ownership of the token
     * @param tokenData Extra data to be used by the factory
     * @return Address of the newly deployed token
     */
    function create(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        address recipient,
        address owner,
        address pool,
        bytes calldata tokenData,
        bytes32 salt
    ) external returns (address);
}
