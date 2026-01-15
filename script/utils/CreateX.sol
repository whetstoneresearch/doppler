// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @dev Generates a salt for a CREATE3 deployment based on the CreateX specifications, this ensures that:
 * - First 20 bytes are the sender's address
 * - 21st byte is always 0x00 to allow cross-chain deployments
 * - Last 11 bytes are derived from the hash of the contract name
 * @param sender Address calling the CreateX factory
 * @param name Name of the contract to be deployed
 * @return bytes32 Generated salt to pass to the CreateX factory
 */
function generateCreate3Salt(address sender, string memory name) pure returns (bytes32) {
    return bytes32(uint256(uint160(sender))) << 96 | keccak256(abi.encode(name)) >> 168;
}

/**
 * @dev Computes the guarded salt as per CreateX specifications
 * @param salt Generated salt for the deployment
 * @param sender Address calling the CreateX factory
 * @return bytes32 Guarded salt to be used in CREATE3 address computation
 */
function computeCreate3GuardedSalt(bytes32 salt, address sender) pure returns (bytes32) {
    return efficientHash({ a: bytes32(uint256(uint160(sender))), b: salt });
}

/**
 * @dev Efficiently hashes two bytes32 values using assembly
 * @param a Value a
 * @param b Value b
 * @return hash Keccak256 hash of the concatenated values
 */
function efficientHash(bytes32 a, bytes32 b) pure returns (bytes32 hash) {
    assembly ("memory-safe") {
        mstore(0x00, a)
        mstore(0x20, b)
        hash := keccak256(0x00, 0x40)
    }
}

/**
 * @dev Computes the CREATE3 address for a deployment
 * @param guardedSalt Guarded salt computed from the original salt and deployer address
 * @param deployer Address of the CreateX factory deploying the contract
 * @return computedAddress Computed address where the contract will be deployed
 */
function computeCreate3Address(bytes32 guardedSalt, address deployer) pure returns (address computedAddress) {
    assembly ("memory-safe") {
        let ptr := mload(0x40)
        mstore(0x00, deployer)
        mstore8(0x0b, 0xff)
        mstore(0x20, guardedSalt)
        mstore(0x40, hex"21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f")
        mstore(0x14, keccak256(0x0b, 0x55))
        mstore(0x40, ptr)
        mstore(0x00, 0xd694)
        mstore8(0x34, 0x01)
        computedAddress := keccak256(0x1e, 0x17)
    }
}
