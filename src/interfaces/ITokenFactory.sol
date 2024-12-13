// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @title Token Factory Interface
 * @notice Contracts deploying new asset token must implement this interface.
 */
interface ITokenFactory {
    /**
     * @notice Deploys a new asset token.
     * @param initialSupply Initial supply that will be minted
     * @param recipient Address receiving the initial supply
     * @param owner Address receiving the ownership of the token
     * @param pool Address of the pool contract
     * @param tokenData Extra data to be used by the factory
     * @param salt Salt used in create2 deployment to determine contract address
     * @return Address of the newly deployed token
     */
    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata tokenData
    ) external returns (address);
}
