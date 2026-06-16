// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ICreateX } from "createx/ICreateX.sol";
import { OwnableRoles } from "solady/auth/OwnableRoles.sol";

/// @title DopplerDeployer
/// @notice Permissioned wrapper around CreateX for deterministic Doppler protocol deployments.
contract DopplerDeployer is OwnableRoles {
    /// @notice Batch call ETH value did not equal the supplied per-call values.
    error PaymentMismatch(uint256 actual, uint256 expected);
    /// @notice Deployed address differed from the caller-supplied expected address.
    error AddressMismatch(address actual, address expected);
    /// @notice A forwarded call reverted.
    error ExecutionFailed();
    /// @notice Deployer role target is invalid for the requested role update.
    error InvalidDeployer();
    /// @notice A role assignment was attempted for an address that already has a role.
    error RoleAlreadyAssigned();
    /// @notice Batch execution arrays must have identical lengths.
    error ArrayLengthsMismatch();

    /// @notice Emitted when the owner grants admin privileges.
    event AdminAdded(address admin);
    /// @notice Emitted when the owner removes admin privileges.
    event AdminRemoved(address admin);
    /// @notice Emitted when an admin or owner grants deployer privileges.
    event DeployerAdded(address indexed admin, address deployer);
    /// @notice Emitted when an admin or owner removes deployer privileges.
    event DeployerRemoved(address indexed admin, address deployer);
    /// @notice Emitted after a successful CreateX deployment.
    event Deployed(address indexed deployer, address deployed);

    /// @notice Canonical CreateX factory used for deployments and address derivation.
    ICreateX public constant CreateX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    uint256 internal constant _ROLE_ADMIN = _ROLE_0;
    uint256 internal constant _ROLE_DEPLOYER = _ROLE_1;
    uint256 internal constant _ROLE_AUTHORIZED = _ROLE_0 | _ROLE_1;

    /// @param newOwner Initial contract owner.
    constructor(address newOwner) {
        _initializeOwner(newOwner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ROLE MANAGEMENT                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Grants admin privileges to each address.
    /// @dev Admins can add and remove deployers, and perform calls and deployments.
    function addAdmins(address[] calldata admins) external onlyOwner {
        for (uint256 i; i < admins.length; ++i) {
            address admin = admins[i];
            _setRoles(admin, _ROLE_ADMIN);
            emit AdminAdded(admin);
        }
    }

    /// @notice Removes all roles from each admin address.
    function removeAdmins(address[] calldata admins) external onlyOwner {
        for (uint256 i; i < admins.length; ++i) {
            address admin = admins[i];
            _setRoles(admin, 0);
            emit AdminRemoved(admin);
        }
    }

    /// @notice Grants deployer privileges to each address.
    /// @dev Each target must not already have a role and cannot be the caller.
    function addDeployers(address[] calldata deployers) external onlyRolesOrOwner(_ROLE_ADMIN) {
        for (uint256 i; i < deployers.length; ++i) {
            address deployer = deployers[i];
            require(rolesOf(deployer) == 0, RoleAlreadyAssigned());
            require(deployer != address(0) && deployer != msg.sender, InvalidDeployer());
            _grantRoles(deployer, _ROLE_DEPLOYER);
            emit DeployerAdded(msg.sender, deployer);
        }
    }

    /// @notice Removes deployer privileges from each address.
    function removeDeployers(address[] calldata deployers) external onlyRolesOrOwner(_ROLE_ADMIN) {
        for (uint256 i; i < deployers.length; ++i) {
            address deployer = deployers[i];
            require(rolesOf(deployer) == _ROLE_DEPLOYER, InvalidDeployer());
            _removeRoles(deployer, _ROLE_DEPLOYER);
            emit DeployerRemoved(msg.sender, deployer);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       SALT FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Generates a deployer-keyed, non-chain-specific CreateX salt.
    /// @dev This is a convenience helper, externally generated valid CreateX salts are also supported.
    function generateSalt(string calldata name, uint256 version) external view returns (bytes32) {
        return bytes32(uint256(uint160(address(this)))) << 96 | keccak256(abi.encode(name, version)) >> 168;
    }

    /// @notice Computes the guarded salt CreateX will use for an explicit salt deployment.
    function computeGuardedSalt(bytes32 salt) external view returns (bytes32) {
        return _guardSalt(salt);
    }

    /// @notice Computes the Create2 address for a salt and init code hash using CreateX guard rules.
    function computeCreate2Address(bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        return CreateX.computeCreate2Address(_guardSalt(salt), initCodeHash);
    }

    /// @notice Computes the Create3 address for a salt using CreateX guard rules.
    function computeCreate3Address(bytes32 salt) external view returns (address) {
        return CreateX.computeCreate3Address(_guardSalt(salt));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   EXECUTION & DEPLOYMENT                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Executes a single call as this contract.
    /// @return Forwarded return data from the target call.
    function execute(
        address target,
        bytes calldata data
    ) external payable onlyRolesOrOwner(_ROLE_AUTHORIZED) returns (bytes memory) {
        (bool success, bytes memory result) = target.call{ value: msg.value }(data);
        require(success, ExecutionFailed());
        return result;
    }

    /// @notice Executes multiple calls as this contract.
    /// @return results Forwarded return data for each target call.
    function execute(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata data
    ) external payable onlyRolesOrOwner(_ROLE_AUTHORIZED) returns (bytes[] memory) {
        require(targets.length == values.length && targets.length == data.length, ArrayLengthsMismatch());

        uint256 totalValue;
        bytes[] memory results = new bytes[](targets.length);
        for (uint256 i; i < targets.length; ++i) {
            bool success;
            (success, results[i]) = targets[i].call{ value: values[i] }(data[i]);
            require(success, ExecutionFailed());
            unchecked {
                totalValue += values[i];
            }
        }

        require(msg.value == totalValue, PaymentMismatch(msg.value, totalValue));
        return results;
    }

    /// @notice Deploys init code through CreateX Create2.
    /// @return deployed Address of the deployed contract.
    function deployCreate2(
        bytes32 salt,
        bytes calldata initCode
    ) external onlyRolesOrOwner(_ROLE_AUTHORIZED) returns (address) {
        address deployed = CreateX.deployCreate2(salt, initCode);
        emit Deployed(msg.sender, deployed);
        return deployed;
    }

    /// @notice Deploys init code through CreateX Create2 and checks the expected address.
    /// @return deployed Address of the deployed contract.
    function deployCreate2(
        bytes32 salt,
        bytes calldata initCode,
        address expected
    ) external onlyRolesOrOwner(_ROLE_AUTHORIZED) returns (address) {
        address deployed = CreateX.deployCreate2(salt, initCode);
        require(deployed == expected, AddressMismatch(deployed, expected));
        emit Deployed(msg.sender, deployed);
        return deployed;
    }

    /// @notice Deploys init code through CreateX Create3.
    /// @return deployed Address of the deployed contract.
    function deployCreate3(
        bytes32 salt,
        bytes calldata initCode
    ) external onlyRolesOrOwner(_ROLE_AUTHORIZED) returns (address) {
        address deployed = CreateX.deployCreate3(salt, initCode);
        emit Deployed(msg.sender, deployed);
        return deployed;
    }

    /// @notice Deploys init code through CreateX Create3 and checks the expected address.
    /// @return deployed Address of the deployed contract.
    function deployCreate3(
        bytes32 salt,
        bytes calldata initCode,
        address expected
    ) external onlyRolesOrOwner(_ROLE_AUTHORIZED) returns (address) {
        address deployed = CreateX.deployCreate3(salt, initCode);
        require(deployed == expected, AddressMismatch(deployed, expected));
        emit Deployed(msg.sender, deployed);
        return deployed;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      INTERNAL HELPERS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Hashes two words using the same packed memory layout as CreateX.
    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }

    /// @dev Mirrors CreateX guarded salts for explicit salt calls, salt validation happens in CreateX.
    function _guardSalt(bytes32 salt) internal view returns (bytes32) {
        address senderBytes = address(bytes20(salt));
        bytes1 redeployProtectionFlag = salt[20];

        if (senderBytes == address(this)) {
            if (redeployProtectionFlag == hex"00") {
                return _efficientHash({ a: bytes32(uint256(uint160(address(this)))), b: salt });
            }
            if (redeployProtectionFlag == hex"01") {
                return keccak256(abi.encode(address(this), block.chainid, salt));
            }
        } else if (senderBytes == address(0) && redeployProtectionFlag == hex"01") {
            return _efficientHash({ a: bytes32(block.chainid), b: salt });
        }

        return keccak256(abi.encode(salt));
    }
}
