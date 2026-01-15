// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Airlock, ModuleState } from "src/Airlock.sol";
import { StreamableFeesLockerV2 } from "src/StreamableFeesLockerV2.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";

event AddSigner(address indexed newSigner);

/// @notice A very basic Airlock-oriented multisig for testing purposes, do not use in production :)
contract AirlockMultisigTestnet {
    mapping(address => bool) public isSigner;

    modifier onlySigner() {
        require(isSigner[msg.sender], "Not a signer");
        _;
    }

    constructor(address[] memory signers) {
        for (uint256 i; i < signers.length; i++) {
            require(signers[i] != address(0), "Signer cannot be zero address");
            isSigner[signers[i]] = true;
        }
    }

    function execute(address target, bytes calldata data) external payable onlySigner {
        (bool success,) = target.call{ value: msg.value }(data);
        require(success, "Execution failed");
    }

    function setModuleState(address payable airlock, address module, ModuleState state) external onlySigner {
        address[] memory modules = new address[](1);
        modules[0] = module;

        ModuleState[] memory states = new ModuleState[](1);
        states[0] = state;

        Airlock(airlock).setModuleState(modules, states);
    }

    function setModuleState(
        address payable airlock,
        address[] calldata modules,
        ModuleState[] calldata states
    ) external onlySigner {
        Airlock(airlock).setModuleState(modules, states);
    }

    function setDopplerHookState(
        address payable dopplerHookInitializer,
        address module,
        uint256 flag
    ) external onlySigner {
        address[] memory modules = new address[](1);
        modules[0] = module;

        uint256[] memory flags = new uint256[](1);
        flags[0] = flag;

        DopplerHookInitializer(dopplerHookInitializer).setDopplerHookState(modules, flags);
    }

    function setDopplerHookState(
        address payable dopplerHookInitializer,
        address[] calldata modules,
        uint256[] calldata flags
    ) external onlySigner {
        DopplerHookInitializer(dopplerHookInitializer).setDopplerHookState(modules, flags);
    }

    function approveMigrator(address payable locker, address migrator) external onlySigner {
        StreamableFeesLockerV2(locker).approveMigrator(migrator);
    }

    function transferOwnership(address payable airlock, address newOwner) external onlySigner {
        Airlock(airlock).transferOwnership(newOwner);
    }

    function addSigner(address newSigner) public onlySigner {
        require(newSigner != address(0), "New signer cannot be zero address");
        require(!isSigner[newSigner], "Already a signer");
        isSigner[newSigner] = true;
        emit AddSigner(newSigner);
    }

    function addSigner(address[] calldata newSigners) external onlySigner {
        for (uint256 i; i < newSigners.length; i++) {
            addSigner(newSigners[i]);
        }
    }
}

