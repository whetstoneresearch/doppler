// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice A very basic multisig for testing purposes, do not use in production :)
contract BasicMultisig {
    mapping(address => bool) public isSigner;

    modifier onlySigner() {
        require(isSigner[msg.sender], "Not a signer");
        _;
    }

    constructor(
        address[] memory signers
    ) {
        for (uint256 i; i < signers.length; ++i) {
            require(signers[i] != address(0), "Signer cannot be zero address");
            isSigner[signers[i]] = true;
        }
    }

    function execute(address to, bytes calldata data) external payable onlySigner {
        (bool success,) = to.call{ value: msg.value }(data);
        require(success, "Execution failed");
    }

    function addSigner(
        address newSigner
    ) external onlySigner {
        require(newSigner != address(0), "New signer cannot be zero address");
        require(!isSigner[newSigner], "Already a signer");
        isSigner[newSigner] = true;
    }
}
