// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Ownable } from "@solady/auth/Ownable.sol";
import { ICreateX } from "createx/ICreateX.sol";
import { Test } from "forge-std/Test.sol";
import { DopplerCreateXDeployer } from "src/DopplerCreateXDeployer.sol";

contract DopplerCreateXDeployerTest is Test {
    event RolesUpdated(address indexed user, uint256 indexed roles);
    event AdminAdded(address admin);
    event AdminRemoved(address admin);
    event RolesRevoked(address indexed addr);
    event DeployerAdded(address indexed admin, address deployer);
    event DeployerRemoved(address indexed admin, address deployer);
    event Deployed(address indexed deployer, address deployed);

    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    uint256 internal constant ROLE_ADMIN = 1;
    uint256 internal constant ROLE_DEPLOYER = 2;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal secondAdmin = makeAddr("secondAdmin");
    address internal authorizedDeployer = makeAddr("authorizedDeployer");
    address internal secondAuthorizedDeployer = makeAddr("secondAuthorizedDeployer");
    address internal stranger = makeAddr("stranger");

    DopplerCreateXDeployer internal deployer;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public {
        _etchCreateX();
        deployer = new DopplerCreateXDeployer(owner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Constructor records the supplied owner.
    function test_constructor_setsOwner() public view {
        assertEq(deployer.owner(), owner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ROLE MANAGEMENT                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Only the owner can grant admin roles and emit the expected events.
    function test_addAdmins_ownerOnly_setsRolesAndEmits() public {
        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, ROLE_ADMIN);
        vm.expectEmit(false, false, false, true, address(deployer));
        emit AdminAdded(admin);
        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(secondAdmin, ROLE_ADMIN);
        vm.expectEmit(false, false, false, true, address(deployer));
        emit AdminAdded(secondAdmin);

        vm.prank(owner);
        deployer.addAdmins(_addresses(admin, secondAdmin));

        assertEq(deployer.rolesOf(admin), ROLE_ADMIN);
        assertTrue(deployer.hasAnyRole(admin, ROLE_ADMIN));
        assertEq(deployer.rolesOf(secondAdmin), ROLE_ADMIN);
        assertTrue(deployer.hasAnyRole(secondAdmin, ROLE_ADMIN));
    }

    /// @notice Non-owners cannot grant admin roles.
    function test_addAdmins_revertUnauthorized() public {
        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.addAdmins(_addresses(admin));
    }

    /// @notice Admins cannot grant admin roles.
    function test_addAdmins_revertAdminCaller() public {
        _addAdmin();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(admin);
        deployer.addAdmins(_addresses(secondAdmin));
    }

    /// @notice Admin grants overwrite any existing deployer role instead of accumulating roles.
    function test_addAdmins_replacesExistingDeployerRole() public {
        vm.prank(owner);
        deployer.addDeployers(_addresses(authorizedDeployer));

        vm.prank(owner);
        deployer.addAdmins(_addresses(authorizedDeployer));

        assertEq(deployer.rolesOf(authorizedDeployer), ROLE_ADMIN);
        assertTrue(deployer.hasAnyRole(authorizedDeployer, ROLE_ADMIN));
        assertFalse(deployer.hasAnyRole(authorizedDeployer, ROLE_DEPLOYER));
    }

    /// @notice Zero address cannot receive admin roles.
    function test_addAdmins_revertZeroAddress() public {
        vm.expectRevert(DopplerCreateXDeployer.InvalidAdmin.selector);

        vm.prank(owner);
        deployer.addAdmins(_addresses(address(0)));
    }

    /// @notice Owner cannot grant admin roles to itself.
    function test_addAdmins_revertCallerAddress() public {
        vm.expectRevert(DopplerCreateXDeployer.InvalidAdmin.selector);

        vm.prank(owner);
        deployer.addAdmins(_addresses(owner));
    }

    /// @notice Owner can remove admin roles and emit the expected events.
    function test_removeAdmins_ownerOnly_clearsRolesAndEmits() public {
        _addAdmins();

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, 0);
        vm.expectEmit(false, false, false, true, address(deployer));
        emit AdminRemoved(admin);
        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(secondAdmin, 0);
        vm.expectEmit(false, false, false, true, address(deployer));
        emit AdminRemoved(secondAdmin);

        vm.prank(owner);
        deployer.removeAdmins(_addresses(admin, secondAdmin));

        assertEq(deployer.rolesOf(admin), 0);
        assertEq(deployer.rolesOf(secondAdmin), 0);
    }

    /// @notice Non-owners cannot remove admin roles.
    function test_removeAdmins_revertUnauthorized() public {
        _addAdmin();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.removeAdmins(_addresses(admin));
    }

    /// @notice Admins cannot remove admin roles.
    function test_removeAdmins_revertAdminCaller() public {
        _addAdmins();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(admin);
        deployer.removeAdmins(_addresses(secondAdmin));
    }

    /// @notice Zero address cannot be removed as an admin.
    function test_removeAdmins_revertZeroAddress() public {
        vm.prank(owner);
        deployer.grantRoles(address(0), ROLE_ADMIN);

        vm.expectRevert(DopplerCreateXDeployer.InvalidAdmin.selector);

        vm.prank(owner);
        deployer.removeAdmins(_addresses(address(0)));
    }

    /// @notice Owner cannot remove itself as an admin through the admin wrapper.
    function test_removeAdmins_revertCallerAddress() public {
        vm.prank(owner);
        deployer.grantRoles(owner, ROLE_ADMIN);

        vm.expectRevert(DopplerCreateXDeployer.InvalidAdmin.selector);

        vm.prank(owner);
        deployer.removeAdmins(_addresses(owner));
    }

    /// @notice Admin removal rejects targets without only admin role.
    function test_removeAdmins_revertIfTargetIsNotAdmin() public {
        _addAuthorizedDeployer();

        vm.expectRevert(DopplerCreateXDeployer.InvalidAdmin.selector);

        vm.prank(owner);
        deployer.removeAdmins(_addresses(authorizedDeployer));
    }

    /// @notice Owner can revoke all roles from admins and deployers.
    function test_revokeRoles_ownerClearsAnyRoleAndEmits() public {
        _addAuthorizedDeployer();

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, 0);
        vm.expectEmit(true, false, false, false, address(deployer));
        emit RolesRevoked(admin);
        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(authorizedDeployer, 0);
        vm.expectEmit(true, false, false, false, address(deployer));
        emit RolesRevoked(authorizedDeployer);

        vm.prank(owner);
        deployer.revokeRoles(_addresses(admin, authorizedDeployer));

        assertEq(deployer.rolesOf(admin), 0);
        assertEq(deployer.rolesOf(authorizedDeployer), 0);
    }

    /// @notice Batch role revocation rejects addresses without existing roles.
    function test_revokeRoles_revertAddressWithoutRoles() public {
        vm.expectRevert(DopplerCreateXDeployer.InvalidAddress.selector);

        vm.prank(owner);
        deployer.revokeRoles(_addresses(stranger));
    }

    /// @notice Non-owners cannot revoke arbitrary roles.
    function test_revokeRoles_revertUnauthorized() public {
        _addAdmin();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.revokeRoles(_addresses(admin));
    }

    /// @notice Admins cannot revoke arbitrary roles through the owner-only wrapper.
    function test_revokeRoles_revertAdminCaller() public {
        _addAuthorizedDeployer();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(admin);
        deployer.revokeRoles(_addresses(authorizedDeployer));
    }

    /// @notice Zero address cannot be revoked through the batch wrapper.
    function test_revokeRoles_revertZeroAddress() public {
        vm.expectRevert(DopplerCreateXDeployer.InvalidAddress.selector);

        vm.prank(owner);
        deployer.revokeRoles(_addresses(address(0)));
    }

    /// @notice Owner cannot revoke its own roles through the batch wrapper.
    function test_revokeRoles_revertCallerAddress() public {
        vm.expectRevert(DopplerCreateXDeployer.InvalidAddress.selector);

        vm.prank(owner);
        deployer.revokeRoles(_addresses(owner));
    }

    /// @notice Inherited role grants accumulate roles and emit inherited events.
    function test_grantRoles_ownerAccumulatesRolesAndEmits() public {
        uint256 roles = ROLE_ADMIN | ROLE_DEPLOYER;

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, roles);

        vm.prank(owner);
        deployer.grantRoles(admin, roles);

        assertEq(deployer.rolesOf(admin), roles);
        assertTrue(deployer.hasAnyRole(admin, ROLE_ADMIN));
        assertTrue(deployer.hasAllRoles(admin, roles));
    }

    /// @notice Non-owner cannot call the inherited role grant.
    function test_grantRoles_revertUnauthorized() public {
        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.grantRoles(admin, ROLE_ADMIN);
    }

    /// @notice Admins cannot call the inherited owner-only role grant.
    function test_grantRoles_revertAdminCaller() public {
        _addAdmin();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(admin);
        deployer.grantRoles(secondAdmin, ROLE_ADMIN);
    }

    /// @notice Inherited role revocation removes only the selected role bits.
    function test_revokeRoles_inheritedOwnerRemovesSelectedRoles() public {
        uint256 roles = ROLE_ADMIN | ROLE_DEPLOYER;

        vm.prank(owner);
        deployer.grantRoles(admin, roles);

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, ROLE_ADMIN);

        vm.prank(owner);
        deployer.revokeRoles(admin, ROLE_DEPLOYER);

        assertEq(deployer.rolesOf(admin), ROLE_ADMIN);
        assertTrue(deployer.hasAnyRole(admin, ROLE_ADMIN));
        assertFalse(deployer.hasAnyRole(admin, ROLE_DEPLOYER));
        assertFalse(deployer.hasAllRoles(admin, roles));
    }

    /// @notice Non-owner cannot call the inherited role revocation.
    function test_revokeRoles_inheritedRevertUnauthorized() public {
        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.revokeRoles(admin, ROLE_ADMIN);
    }

    /// @notice Admins cannot call the inherited owner-only role revocation.
    function test_revokeRoles_inheritedRevertAdminCaller() public {
        _addAdmin();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(admin);
        deployer.revokeRoles(admin, ROLE_ADMIN);
    }

    /// @notice Callers can renounce their own inherited roles.
    function test_renounceRoles_callerRemovesOwnRoles() public {
        uint256 roles = ROLE_ADMIN | ROLE_DEPLOYER;

        vm.prank(owner);
        deployer.grantRoles(admin, roles);

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, ROLE_DEPLOYER);

        vm.prank(admin);
        deployer.renounceRoles(ROLE_ADMIN);

        assertEq(deployer.rolesOf(admin), ROLE_DEPLOYER);
    }

    /// @notice Admin removal clears all roles when the target has mixed roles.
    function test_removeAdmins_clearsInheritedMixedRoleTarget() public {
        vm.prank(owner);
        deployer.grantRoles(admin, ROLE_ADMIN | ROLE_DEPLOYER);

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, 0);
        vm.expectEmit(false, false, false, true, address(deployer));
        emit AdminRemoved(admin);

        vm.prank(owner);
        deployer.removeAdmins(_addresses(admin));

        assertEq(deployer.rolesOf(admin), 0);
    }

    /// @notice Admin can grant deployer roles and emit the expected events.
    function test_addDeployers_adminCanGrantDeployerRoles() public {
        _addAdmin();

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(authorizedDeployer, ROLE_DEPLOYER);
        vm.expectEmit(true, false, false, true, address(deployer));
        emit DeployerAdded(admin, authorizedDeployer);
        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(secondAuthorizedDeployer, ROLE_DEPLOYER);
        vm.expectEmit(true, false, false, true, address(deployer));
        emit DeployerAdded(admin, secondAuthorizedDeployer);

        vm.prank(admin);
        deployer.addDeployers(_addresses(authorizedDeployer, secondAuthorizedDeployer));

        assertEq(deployer.rolesOf(authorizedDeployer), ROLE_DEPLOYER);
        assertTrue(deployer.hasAnyRole(authorizedDeployer, ROLE_DEPLOYER));
        assertEq(deployer.rolesOf(secondAuthorizedDeployer), ROLE_DEPLOYER);
        assertTrue(deployer.hasAnyRole(secondAuthorizedDeployer, ROLE_DEPLOYER));
    }

    /// @notice Owner can grant deployer roles.
    function test_addDeployers_ownerCanGrantDeployerRoles() public {
        vm.prank(owner);
        deployer.addDeployers(_addresses(authorizedDeployer, secondAuthorizedDeployer));

        assertEq(deployer.rolesOf(authorizedDeployer), ROLE_DEPLOYER);
        assertEq(deployer.rolesOf(secondAuthorizedDeployer), ROLE_DEPLOYER);
    }

    /// @notice Deployer grants overwrite any existing admin role instead of accumulating roles.
    function test_addDeployers_replacesExistingAdminRole() public {
        _addAdmins();

        vm.prank(owner);
        deployer.addDeployers(_addresses(secondAdmin));

        assertEq(deployer.rolesOf(secondAdmin), ROLE_DEPLOYER);
        assertFalse(deployer.hasAnyRole(secondAdmin, ROLE_ADMIN));
        assertTrue(deployer.hasAnyRole(secondAdmin, ROLE_DEPLOYER));
    }

    /// @notice Unauthorized callers cannot grant deployer roles.
    function test_addDeployers_revertUnauthorized() public {
        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.addDeployers(_addresses(authorizedDeployer));
    }

    /// @notice Deployer-role callers cannot grant deployer roles.
    function test_addDeployers_revertDeployerCaller() public {
        _addAuthorizedDeployer();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(authorizedDeployer);
        deployer.addDeployers(_addresses(secondAuthorizedDeployer));
    }

    /// @notice Zero address cannot receive deployer roles.
    function test_addDeployers_revertZeroAddress() public {
        vm.expectRevert(DopplerCreateXDeployer.InvalidDeployer.selector);

        vm.prank(owner);
        deployer.addDeployers(_addresses(address(0)));
    }

    /// @notice Caller cannot grant deployer roles to itself.
    function test_addDeployers_revertCallerAddress() public {
        vm.expectRevert(DopplerCreateXDeployer.InvalidDeployer.selector);

        vm.prank(owner);
        deployer.addDeployers(_addresses(owner));
    }

    /// @notice Admin can revoke deployer roles and emit the expected events.
    function test_removeDeployers_adminCanRevokeDeployerRoles() public {
        _addAuthorizedDeployers();

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(authorizedDeployer, 0);
        vm.expectEmit(true, false, false, true, address(deployer));
        emit DeployerRemoved(admin, authorizedDeployer);
        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(secondAuthorizedDeployer, 0);
        vm.expectEmit(true, false, false, true, address(deployer));
        emit DeployerRemoved(admin, secondAuthorizedDeployer);

        vm.prank(admin);
        deployer.removeDeployers(_addresses(authorizedDeployer, secondAuthorizedDeployer));

        assertEq(deployer.rolesOf(authorizedDeployer), 0);
        assertEq(deployer.rolesOf(secondAuthorizedDeployer), 0);
    }

    /// @notice Owner can revoke deployer roles.
    function test_removeDeployers_ownerCanRevokeDeployerRoles() public {
        _addAuthorizedDeployers();

        vm.prank(owner);
        deployer.removeDeployers(_addresses(authorizedDeployer, secondAuthorizedDeployer));

        assertEq(deployer.rolesOf(authorizedDeployer), 0);
        assertEq(deployer.rolesOf(secondAuthorizedDeployer), 0);
    }

    /// @notice Unauthorized callers cannot revoke deployer roles.
    function test_removeDeployers_revertUnauthorized() public {
        _addAuthorizedDeployer();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.removeDeployers(_addresses(authorizedDeployer));
    }

    /// @notice Deployer-role callers cannot revoke deployer roles.
    function test_removeDeployers_revertDeployerCaller() public {
        _addAuthorizedDeployers();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(authorizedDeployer);
        deployer.removeDeployers(_addresses(secondAuthorizedDeployer));
    }

    /// @notice Deployer removal rejects targets without only deployer role.
    function test_removeDeployers_revertIfTargetIsNotDeployer() public {
        _addAdmin();

        vm.expectRevert(DopplerCreateXDeployer.InvalidDeployer.selector);

        vm.prank(owner);
        deployer.removeDeployers(_addresses(admin));
    }

    /// @notice Deployer removal clears all roles when the target has mixed roles.
    function test_removeDeployers_clearsInheritedMixedRoleTarget() public {
        vm.prank(owner);
        deployer.grantRoles(authorizedDeployer, ROLE_ADMIN | ROLE_DEPLOYER);

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(authorizedDeployer, 0);
        vm.expectEmit(true, false, false, true, address(deployer));
        emit DeployerRemoved(owner, authorizedDeployer);

        vm.prank(owner);
        deployer.removeDeployers(_addresses(authorizedDeployer));

        assertEq(deployer.rolesOf(authorizedDeployer), 0);
    }

    /// @notice Zero address cannot be removed as a deployer.
    function test_removeDeployers_revertZeroAddress() public {
        vm.prank(owner);
        deployer.grantRoles(address(0), ROLE_DEPLOYER);

        vm.expectRevert(DopplerCreateXDeployer.InvalidDeployer.selector);

        vm.prank(owner);
        deployer.removeDeployers(_addresses(address(0)));
    }

    /// @notice Owner caller cannot remove itself through the deployer removal wrapper.
    function test_removeDeployers_revertCallerAddress() public {
        vm.prank(owner);
        deployer.grantRoles(owner, ROLE_DEPLOYER);

        vm.expectRevert(DopplerCreateXDeployer.InvalidDeployer.selector);

        vm.prank(owner);
        deployer.removeDeployers(_addresses(owner));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       SALT FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Generated salts are deployer-keyed with name and version entropy.
    function test_generateSalt_usesDeployerAddressAndNameVersionEntropy() public view {
        bytes32 salt = deployer.generateSalt("DopplerCreateXDeployer", 2);
        bytes32 expected = bytes32(uint256(uint160(address(deployer))) << 96)
            | bytes32(uint256(keccak256(abi.encode("DopplerCreateXDeployer", uint256(2)))) >> 168);

        assertEq(salt, expected);
        assertEq(address(bytes20(salt)), address(deployer));
        assertEq(bytes1(salt[20]), hex"00");
    }

    /// @notice Guarded salt derivation for deployer-keyed salts without redeploy protection.
    function test_computeGuardedSalt_permissionedNoRedeployProtection() public view {
        bytes32 salt = deployer.generateSalt("Contract", 1);
        bytes32 expected = _efficientHash(bytes32(uint256(uint160(address(deployer)))), salt);

        assertEq(deployer.computeGuardedSalt(salt), expected);
    }

    /// @notice Guarded salt derivation for deployer-keyed salts with redeploy protection.
    function test_computeGuardedSalt_deployerWithRedeployProtection() public view {
        bytes32 salt = _salt(address(deployer), 1, 0x1234);
        bytes32 expected = keccak256(abi.encode(address(deployer), block.chainid, salt));

        assertEq(deployer.computeGuardedSalt(salt), expected);
    }

    /// @notice Guarded salt derivation for zero-address salts without redeploy protection.
    function test_computeGuardedSalt_zeroAddressNoRedeployProtection() public view {
        bytes32 salt = _salt(address(0), 0, 0xbeef);
        bytes32 expected = keccak256(abi.encode(salt));

        assertEq(deployer.computeGuardedSalt(salt), expected);
    }

    /// @notice Guarded salt derivation for zero-address salts with redeploy protection.
    function test_computeGuardedSalt_zeroAddressWithRedeployProtection() public view {
        bytes32 salt = _salt(address(0), 1, 0xbeef);
        bytes32 expected = _efficientHash(bytes32(block.chainid), salt);

        assertEq(deployer.computeGuardedSalt(salt), expected);
    }

    /// @notice Guarded salt derivation for permissionless random sender-byte salts.
    function test_computeGuardedSalt_randomSenderBytes() public view {
        bytes32 salt = _salt(address(0x1234), 0, 0xbeef);
        bytes32 expected = keccak256(abi.encode(salt));

        assertEq(deployer.computeGuardedSalt(salt), expected);
    }

    /// @notice Create2 address computation matches CreateX guarded-salt computation.
    function test_computeCreate2Address_matchesCreateXGuardedSalt() public view {
        bytes memory initCode = _deployableInitCode(42);
        bytes32 salt = deployer.generateSalt("Create2", 1);
        bytes32 guardedSalt = deployer.computeGuardedSalt(salt);
        address expected = ICreateX(CREATEX).computeCreate2Address(guardedSalt, keccak256(initCode));

        assertEq(deployer.computeCreate2Address(salt, keccak256(initCode)), expected);
    }

    /// @notice Create3 address computation matches CreateX guarded-salt computation.
    function test_computeCreate3Address_matchesCreateXGuardedSalt() public view {
        bytes32 salt = deployer.generateSalt("Create3", 1);
        bytes32 guardedSalt = deployer.computeGuardedSalt(salt);
        address expected = ICreateX(CREATEX).computeCreate3Address(guardedSalt);

        assertEq(deployer.computeCreate3Address(salt), expected);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CREATE2 DEPLOYMENT                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Owner can deploy with Create2 to the computed address.
    function test_deployCreate2_ownerDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(42);
        bytes32 salt = deployer.generateSalt("Create2Owner", 1);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));
        vm.deal(owner, 1 ether);

        vm.expectEmit(true, false, false, true, address(deployer));
        emit Deployed(owner, expected);

        vm.prank(owner);
        address deployed = deployer.deployCreate2{ value: 0.1 ether }(salt, initCode);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 42);
        assertEq(DeployableContract(deployed).constructorValue(), 0.1 ether);
        assertEq(DeployableContract(deployed).constructorSender(), CREATEX);
        assertEq(deployed.balance, 0.1 ether);
    }

    /// @notice Deployer role can deploy with default salt and expected-address check.
    function test_deployCreate2_deployerRoleDeploysDefaultSaltToExpectedAddress() public {
        _addAuthorizedDeployer();

        bytes memory initCode = _deployableInitCode(43);
        bytes32 salt = deployer.generateSalt("Create2Expected", 1);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));
        vm.deal(authorizedDeployer, 1 ether);

        vm.expectEmit(true, false, false, true, address(deployer));
        emit Deployed(authorizedDeployer, expected);

        vm.prank(authorizedDeployer);
        address deployed = deployer.deployCreate2{ value: 0.2 ether }(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 43);
        assertEq(DeployableContract(deployed).constructorValue(), 0.2 ether);
        assertEq(deployed.balance, 0.2 ether);
    }

    /// @notice Admin role can deploy with Create2 through the authorized deployment surface.
    function test_deployCreate2_adminRoleDeploysToComputedAddress() public {
        _addAdmin();

        bytes memory initCode = _deployableInitCode(54);
        bytes32 salt = deployer.generateSalt("Create2Admin", 1);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));

        vm.prank(admin);
        address deployed = deployer.deployCreate2(salt, initCode);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 54);
    }

    /// @notice Create2 deployment for deployer-keyed salts with redeploy protection.
    function test_deployCreate2_deployerRedeployProtectionSaltDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(48);
        bytes32 salt = _salt(address(deployer), 1, 0x1234);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));

        vm.prank(owner);
        address deployed = deployer.deployCreate2(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 48);
    }

    /// @notice Create2 deployment for zero-address salts without redeploy protection.
    function test_deployCreate2_zeroAddressSaltDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(49);
        bytes32 salt = _salt(address(0), 0, 0x1234);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));

        vm.prank(owner);
        address deployed = deployer.deployCreate2(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 49);
    }

    /// @notice Create2 deployment for zero-address salts with redeploy protection.
    function test_deployCreate2_zeroAddressRedeployProtectionSaltDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(50);
        bytes32 salt = _salt(address(0), 1, 0x1234);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));

        vm.prank(owner);
        address deployed = deployer.deployCreate2(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 50);
    }

    /// @notice Create2 expected-address mismatch reverts and rolls back deployment.
    function test_deployCreate2_revertExpectedAddressMismatch() public {
        bytes memory initCode = _deployableInitCode(44);
        bytes32 salt = deployer.generateSalt("Create2Mismatch", 1);
        address actual = deployer.computeCreate2Address(salt, keccak256(initCode));
        address wrongExpected = makeAddr("wrongExpected");

        vm.expectRevert(abi.encodeWithSelector(DopplerCreateXDeployer.AddressMismatch.selector, actual, wrongExpected));

        vm.prank(owner);
        deployer.deployCreate2(salt, initCode, wrongExpected);

        assertEq(actual.code.length, 0);
    }

    /// @notice Unauthorized callers cannot deploy with Create2.
    function test_deployCreate2_revertUnauthorized() public {
        bytes32 salt = deployer.generateSalt("Unauthorized", 1);
        bytes memory initCode = _deployableInitCode(1);

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.deployCreate2(salt, initCode);
    }

    /// @notice Unauthorized callers cannot deploy with Create2 expected-address checks.
    function test_deployCreate2Expected_revertUnauthorized() public {
        bytes memory initCode = _deployableInitCode(1);
        bytes32 salt = deployer.generateSalt("ExpectedUnauthorized", 1);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.deployCreate2(salt, initCode, expected);
    }

    /// @notice Invalid Create2 salts revert from CreateX.
    function test_deployCreate2_revertInvalidSaltFromCreateX() public {
        bytes32 salt = _salt(address(deployer), 2, 0x1234);

        vm.expectRevert(abi.encodeWithSelector(ICreateX.InvalidSalt.selector, CREATEX));

        vm.prank(owner);
        deployer.deployCreate2(salt, _deployableInitCode(1));
    }

    /// @notice Create2 forwards constructor value and CreateX rejects non-payable init code.
    function test_deployCreate2_revertNonPayableConstructorWithValue() public {
        bytes memory initCode = type(NonPayableDeployableContract).creationCode;
        bytes32 salt = deployer.generateSalt("Create2NonPayable", 1);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));
        vm.deal(owner, 1 wei);

        vm.expectRevert(abi.encodeWithSelector(ICreateX.FailedContractCreation.selector, CREATEX));

        vm.prank(owner);
        deployer.deployCreate2{ value: 1 wei }(salt, initCode);

        assertEq(expected.code.length, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CREATE3 DEPLOYMENT                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Owner can deploy with Create3 to the computed address.
    function test_deployCreate3_ownerDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(45);
        bytes32 salt = deployer.generateSalt("Create3Owner", 1);
        address expected = deployer.computeCreate3Address(salt);
        vm.deal(owner, 1 ether);

        vm.expectEmit(true, false, false, true, address(deployer));
        emit Deployed(owner, expected);

        vm.prank(owner);
        address deployed = deployer.deployCreate3{ value: 0.3 ether }(salt, initCode);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 45);
        assertEq(DeployableContract(deployed).constructorValue(), 0.3 ether);
        assertEq(deployed.balance, 0.3 ether);
    }

    /// @notice Deployer role can deploy with Create3 and expected-address check.
    function test_deployCreate3_deployerRoleDeploysToExpectedAddress() public {
        _addAuthorizedDeployer();

        bytes memory initCode = _deployableInitCode(46);
        bytes32 salt = deployer.generateSalt("Create3Expected", 1);
        address expected = deployer.computeCreate3Address(salt);
        vm.deal(authorizedDeployer, 1 ether);

        vm.expectEmit(true, false, false, true, address(deployer));
        emit Deployed(authorizedDeployer, expected);

        vm.prank(authorizedDeployer);
        address deployed = deployer.deployCreate3{ value: 0.4 ether }(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 46);
        assertEq(DeployableContract(deployed).constructorValue(), 0.4 ether);
        assertEq(deployed.balance, 0.4 ether);
    }

    /// @notice Admin role can deploy with Create3 through the authorized deployment surface.
    function test_deployCreate3_adminRoleDeploysToComputedAddress() public {
        _addAdmin();

        bytes memory initCode = _deployableInitCode(55);
        bytes32 salt = deployer.generateSalt("Create3Admin", 1);
        address expected = deployer.computeCreate3Address(salt);

        vm.prank(admin);
        address deployed = deployer.deployCreate3(salt, initCode);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 55);
    }

    /// @notice Create3 deployment for deployer-keyed salts with redeploy protection.
    function test_deployCreate3_deployerRedeployProtectionSaltDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(51);
        bytes32 salt = _salt(address(deployer), 1, 0x1234);
        address expected = deployer.computeCreate3Address(salt);

        vm.prank(owner);
        address deployed = deployer.deployCreate3(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 51);
    }

    /// @notice Create3 deployment for zero-address salts without redeploy protection.
    function test_deployCreate3_zeroAddressSaltDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(52);
        bytes32 salt = _salt(address(0), 0, 0x1234);
        address expected = deployer.computeCreate3Address(salt);

        vm.prank(owner);
        address deployed = deployer.deployCreate3(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 52);
    }

    /// @notice Create3 deployment for zero-address salts with redeploy protection.
    function test_deployCreate3_zeroAddressRedeployProtectionSaltDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(53);
        bytes32 salt = _salt(address(0), 1, 0x1234);
        address expected = deployer.computeCreate3Address(salt);

        vm.prank(owner);
        address deployed = deployer.deployCreate3(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 53);
    }

    /// @notice Create3 expected-address mismatch reverts and rolls back deployment.
    function test_deployCreate3_revertExpectedAddressMismatch() public {
        bytes memory initCode = _deployableInitCode(47);
        bytes32 salt = deployer.generateSalt("Create3Mismatch", 1);
        address actual = deployer.computeCreate3Address(salt);
        address wrongExpected = makeAddr("wrongExpected");

        vm.expectRevert(abi.encodeWithSelector(DopplerCreateXDeployer.AddressMismatch.selector, actual, wrongExpected));

        vm.prank(owner);
        deployer.deployCreate3(salt, initCode, wrongExpected);

        assertEq(actual.code.length, 0);
    }

    /// @notice Unauthorized callers cannot deploy with Create3.
    function test_deployCreate3_revertUnauthorized() public {
        bytes32 salt = deployer.generateSalt("Create3Unauthorized", 1);

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.deployCreate3(salt, _deployableInitCode(1));
    }

    /// @notice Unauthorized callers cannot deploy with Create3 expected-address checks.
    function test_deployCreate3Expected_revertUnauthorized() public {
        bytes memory initCode = _deployableInitCode(1);
        bytes32 salt = deployer.generateSalt("Create3ExpectedUnauthorized", 1);
        address expected = deployer.computeCreate3Address(salt);

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.deployCreate3(salt, initCode, expected);
    }

    /// @notice Invalid Create3 salts revert from CreateX.
    function test_deployCreate3_revertInvalidSaltFromCreateX() public {
        vm.expectRevert(abi.encodeWithSelector(ICreateX.InvalidSalt.selector, CREATEX));

        vm.prank(owner);
        deployer.deployCreate3(_salt(address(deployer), 2, 0x1234), _deployableInitCode(1));
    }

    /// @notice Create3 forwards constructor value and CreateX rejects non-payable init code.
    function test_deployCreate3_revertNonPayableConstructorWithValue() public {
        bytes32 salt = deployer.generateSalt("Create3NonPayable", 1);
        address expected = deployer.computeCreate3Address(salt);
        vm.deal(owner, 1 wei);

        vm.expectRevert(abi.encodeWithSelector(ICreateX.FailedContractCreation.selector, CREATEX));

        vm.prank(owner);
        deployer.deployCreate3{ value: 1 wei }(salt, type(NonPayableDeployableContract).creationCode);

        assertEq(expected.code.length, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EXECUTION                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Authorized single-call execution forwards value and return data.
    function test_execute_singleCallForwardsValueAndReturnsData() public {
        CallTarget target = new CallTarget();
        vm.deal(authorizedDeployer, 1 ether);
        _addAuthorizedDeployer();

        vm.prank(authorizedDeployer);
        bytes memory result =
            deployer.execute{ value: 0.25 ether }(address(target), abi.encodeCall(CallTarget.store, (11)));

        assertEq(abi.decode(result, (uint256)), 12);
        assertEq(target.value(), 11);
        assertEq(target.received(), 0.25 ether);
    }

    /// @notice Admin role can execute through the authorized execution surface.
    function test_execute_singleCallAdminCanExecute() public {
        CallTarget target = new CallTarget();
        _addAdmin();

        vm.prank(admin);
        bytes memory result = deployer.execute(address(target), abi.encodeCall(CallTarget.store, (12)));

        assertEq(abi.decode(result, (uint256)), 13);
        assertEq(target.value(), 12);
    }

    /// @notice Unauthorized callers cannot execute a single call.
    function test_execute_singleCallRevertUnauthorized() public {
        CallTarget target = new CallTarget();

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.execute(address(target), abi.encodeCall(CallTarget.store, (1)));
    }

    /// @notice Failed single-call execution reverts with ExecutionFailed.
    function test_execute_singleCallRevertExecutionFailed() public {
        CallTarget target = new CallTarget();

        vm.expectRevert(DopplerCreateXDeployer.ExecutionFailed.selector);

        vm.prank(owner);
        deployer.execute(address(target), abi.encodeCall(CallTarget.fail, ()));
    }

    /// @notice Authorized batch execution forwards values and return data.
    function test_execute_batchCallsForwardValuesAndReturnData() public {
        CallTarget first = new CallTarget();
        CallTarget second = new CallTarget();
        vm.deal(owner, 3 wei);

        address[] memory targets = new address[](2);
        targets[0] = address(first);
        targets[1] = address(second);

        uint256[] memory values = new uint256[](2);
        values[0] = 1 wei;
        values[1] = 2 wei;

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(CallTarget.store, (20));
        data[1] = abi.encodeCall(CallTarget.store, (30));

        vm.prank(owner);
        bytes[] memory results = deployer.execute{ value: 3 wei }(targets, values, data);

        assertEq(abi.decode(results[0], (uint256)), 21);
        assertEq(abi.decode(results[1], (uint256)), 31);
        assertEq(first.value(), 20);
        assertEq(first.received(), 1 wei);
        assertEq(second.value(), 30);
        assertEq(second.received(), 2 wei);
    }

    /// @notice Admin and deployer roles can execute batches through the authorized execution surface.
    function test_execute_batchAdminAndDeployerCanExecute() public {
        CallTarget adminTarget = new CallTarget();
        CallTarget deployerTarget = new CallTarget();
        _addAuthorizedDeployer();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        targets[0] = address(adminTarget);
        data[0] = abi.encodeCall(CallTarget.store, (40));

        vm.prank(admin);
        bytes[] memory adminResults = deployer.execute(targets, values, data);

        targets[0] = address(deployerTarget);
        data[0] = abi.encodeCall(CallTarget.store, (50));

        vm.prank(authorizedDeployer);
        bytes[] memory deployerResults = deployer.execute(targets, values, data);

        assertEq(abi.decode(adminResults[0], (uint256)), 41);
        assertEq(adminTarget.value(), 40);
        assertEq(abi.decode(deployerResults[0], (uint256)), 51);
        assertEq(deployerTarget.value(), 50);
    }

    /// @notice Authorized batch execution supports empty batches.
    function test_execute_batchAllowsEmptyCalls() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory data = new bytes[](0);

        vm.prank(owner);
        bytes[] memory results = deployer.execute(targets, values, data);

        assertEq(results.length, 0);
    }

    /// @notice Unauthorized callers cannot execute batch calls.
    function test_execute_batchRevertUnauthorized() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory data = new bytes[](0);

        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.execute(targets, values, data);
    }

    /// @notice Batch execution rejects mismatched input array lengths.
    function test_execute_batchRevertValueArrayLengthMismatch() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](1);

        vm.expectRevert(DopplerCreateXDeployer.ArrayLengthsMismatch.selector);

        vm.prank(owner);
        deployer.execute(targets, values, data);
    }

    /// @notice Batch execution rejects mismatched calldata array length.
    function test_execute_batchRevertDataArrayLengthMismatch() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](2);

        vm.expectRevert(DopplerCreateXDeployer.ArrayLengthsMismatch.selector);

        vm.prank(owner);
        deployer.execute(targets, values, data);
    }

    /// @notice Batch payment mismatch reverts and rolls back prior calls.
    function test_execute_batchRevertPaymentMismatchAndRollsBackCalls() public {
        CallTarget first = new CallTarget();
        CallTarget second = new CallTarget();
        vm.deal(owner, 3 wei);

        address[] memory targets = new address[](2);
        targets[0] = address(first);
        targets[1] = address(second);

        uint256[] memory values = new uint256[](2);
        values[0] = 1 wei;
        values[1] = 1 wei;

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(CallTarget.store, (20));
        data[1] = abi.encodeCall(CallTarget.store, (30));

        vm.expectRevert(abi.encodeWithSelector(DopplerCreateXDeployer.PaymentMismatch.selector, 3, 2));

        vm.prank(owner);
        deployer.execute{ value: 3 wei }(targets, values, data);

        assertEq(first.value(), 0);
        assertEq(second.value(), 0);
    }

    /// @notice Failed batch execution reverts with ExecutionFailed.
    function test_execute_batchRevertExecutionFailed() public {
        CallTarget target = new CallTarget();

        address[] memory targets = new address[](1);
        targets[0] = address(target);

        uint256[] memory values = new uint256[](1);

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeCall(CallTarget.fail, ());

        vm.expectRevert(DopplerCreateXDeployer.ExecutionFailed.selector);

        vm.prank(owner);
        deployer.execute(targets, values, data);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         TEST HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _addAdmin() internal {
        vm.prank(owner);
        deployer.addAdmins(_addresses(admin));
    }

    function _addAdmins() internal {
        vm.prank(owner);
        deployer.addAdmins(_addresses(admin, secondAdmin));
    }

    function _addAuthorizedDeployer() internal {
        _addAdmin();

        vm.prank(admin);
        deployer.addDeployers(_addresses(authorizedDeployer));
    }

    function _addAuthorizedDeployers() internal {
        _addAdmin();

        vm.prank(admin);
        deployer.addDeployers(_addresses(authorizedDeployer, secondAuthorizedDeployer));
    }

    function _addresses(address first) internal pure returns (address[] memory addresses) {
        addresses = new address[](1);
        addresses[0] = first;
    }

    function _addresses(address first, address second) internal pure returns (address[] memory addresses) {
        addresses = new address[](2);
        addresses[0] = first;
        addresses[1] = second;
    }

    function _deployableInitCode(uint256 value) internal pure returns (bytes memory) {
        return abi.encodePacked(type(DeployableContract).creationCode, abi.encode(value));
    }

    function _etchCreateX() internal {
        string memory artifact = vm.readFile("lib/createx/artifacts/src/CreateX.sol/CreateX.json");
        bytes memory creationCode = vm.parseJsonBytes(artifact, ".bytecode");

        vm.etch(CREATEX, creationCode);
        (bool success, bytes memory runtimeBytecode) = CREATEX.call("");
        require(success, "CreateX init failed");
        vm.etch(CREATEX, runtimeBytecode);
        assertGt(CREATEX.code.length, 0);
    }

    function _salt(address senderBytes, uint8 redeployProtectionFlag, uint88 entropy) internal pure returns (bytes32) {
        return
            bytes32((uint256(uint160(senderBytes)) << 96) | (uint256(redeployProtectionFlag) << 88) | uint256(entropy));
    }

    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         TEST CONTRACTS                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract DeployableContract {
    uint256 public immutable value;
    uint256 public immutable constructorValue;
    address public immutable constructorSender;

    constructor(uint256 value_) payable {
        value = value_;
        constructorValue = msg.value;
        constructorSender = msg.sender;
    }
}

contract NonPayableDeployableContract { }

contract CallTarget {
    error TargetFailed();

    uint256 public value;
    uint256 public received;

    function store(uint256 value_) external payable returns (uint256) {
        value = value_;
        received += msg.value;
        return value_ + 1;
    }

    function fail() external pure {
        revert TargetFailed();
    }
}
