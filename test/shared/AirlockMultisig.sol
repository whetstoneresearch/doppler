// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Airlock, ModuleState } from "src/Airlock.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";

/// @notice A very basic Airlock-oriented multisig for testing purposes, do not use in production :)
contract AirlockMultisig {
    Airlock public immutable airlock;
    mapping(address => bool) public isSigner;

    modifier onlySigner() {
        require(isSigner[msg.sender], "Not a signer");
        _;
    }

    constructor(
        Airlock airlock_,
        address[] memory signers
    ) {
        airlock = airlock_;

        for (uint256 i; i < signers.length; ++i) {
            require(signers[i] != address(0), "Signer cannot be zero address");
            isSigner[signers[i]] = true;
        }
    }

    function execute(
        address target,
        bytes calldata data
    ) external payable onlySigner {
        (bool success,) = target.call{ value: msg.value }(data);
        require(success, "Execution failed");
    }

    function setModuleState(
        address module,
        ModuleState state
    ) external onlySigner {
        address[] memory modules = new address[](1);
        modules[0] = module;

        ModuleState[] memory states = new ModuleState[](1);
        states[0] = state;

        airlock.setModuleState(modules, states);
    }

    function setModuleState(
        address[] calldata modules,
        ModuleState[] calldata states
    ) external onlySigner {
        airlock.setModuleState(modules, states);
    }

    function transferOwnership(
        address newOwner
    ) external onlySigner {
        airlock.transferOwnership(newOwner);
    }

    function addSigner(
        address newSigner
    ) external onlySigner {
        require(newSigner != address(0), "New signer cannot be zero address");
        require(!isSigner[newSigner], "Already a signer");
        isSigner[newSigner] = true;
    }

    function approveMigrator(
        address locker,
        address migrator
    ) external onlySigner {
        StreamableFeesLockerV2(payable(locker)).approveMigrator(migrator);
    }
}
