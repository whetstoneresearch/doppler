// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Ownable } from "@solady/auth/Ownable.sol";
import { ICreateX } from "createx/ICreateX.sol";
import { Test } from "forge-std/Test.sol";
import { DopplerDeployer } from "src/DopplerDeployer.sol";

contract DopplerDeployerTest is Test {
    event RolesUpdated(address indexed user, uint256 indexed roles);
    event AdminAdded(address admin);
    event AdminRemoved(address admin);
    event DeployerAdded(address indexed admin, address deployer);
    event DeployerRemoved(address indexed admin, address deployer);
    event Deployed(address indexed deployer, address deployed);

    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    uint256 internal constant ROLE_ADMIN = 1;
    uint256 internal constant ROLE_DEPLOYER = 2;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal authorizedDeployer = makeAddr("authorizedDeployer");
    address internal stranger = makeAddr("stranger");

    DopplerDeployer internal deployer;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public {
        _etchCreateX();
        deployer = new DopplerDeployer(owner);
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

    /// @notice Only the owner can grant admin role and emit the expected events.
    function test_addAdmin_ownerOnly_setsRoleAndEmits() public {
        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, ROLE_ADMIN);
        vm.expectEmit(false, false, false, true, address(deployer));
        emit AdminAdded(admin);

        vm.prank(owner);
        deployer.addAdmin(admin);

        assertEq(deployer.rolesOf(admin), ROLE_ADMIN);
        assertTrue(deployer.hasAnyRole(admin, ROLE_ADMIN));
    }

    /// @notice Non-owners cannot grant admin role.
    function test_addAdmin_revertUnauthorized() public {
        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.addAdmin(admin);
    }

    /// @notice Owner can remove admin role and emit the expected events.
    function test_removeAdmin_ownerOnly_clearsRoleAndEmits() public {
        _addAdmin();

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(admin, 0);
        vm.expectEmit(false, false, false, true, address(deployer));
        emit AdminRemoved(admin);

        vm.prank(owner);
        deployer.removeAdmin(admin);

        assertEq(deployer.rolesOf(admin), 0);
    }

    /// @notice Admin can grant deployer role and emit the expected events.
    function test_addDeployer_adminCanGrantDeployerRole() public {
        _addAdmin();

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(authorizedDeployer, ROLE_DEPLOYER);
        vm.expectEmit(true, false, false, true, address(deployer));
        emit DeployerAdded(admin, authorizedDeployer);

        vm.prank(admin);
        deployer.addDeployer(authorizedDeployer);

        assertEq(deployer.rolesOf(authorizedDeployer), ROLE_DEPLOYER);
        assertTrue(deployer.hasAnyRole(authorizedDeployer, ROLE_DEPLOYER));
    }

    /// @notice Owner can grant deployer role.
    function test_addDeployer_ownerCanGrantDeployerRole() public {
        vm.prank(owner);
        deployer.addDeployer(authorizedDeployer);

        assertEq(deployer.rolesOf(authorizedDeployer), ROLE_DEPLOYER);
    }

    /// @notice Unauthorized callers cannot grant deployer role.
    function test_addDeployer_revertUnauthorized() public {
        vm.expectRevert(Ownable.Unauthorized.selector);

        vm.prank(stranger);
        deployer.addDeployer(authorizedDeployer);
    }

    /// @notice Zero address cannot receive deployer role.
    function test_addDeployer_revertZeroAddress() public {
        vm.expectRevert(DopplerDeployer.InvalidDeployer.selector);

        vm.prank(owner);
        deployer.addDeployer(address(0));
    }

    /// @notice Caller cannot grant deployer role to itself.
    function test_addDeployer_revertCallerAddress() public {
        vm.expectRevert(DopplerDeployer.InvalidDeployer.selector);

        vm.prank(owner);
        deployer.addDeployer(owner);
    }

    /// @notice Addresses with any existing role cannot receive deployer role.
    function test_addDeployer_revertRoleAlreadyAssigned() public {
        _addAdmin();

        vm.expectRevert(DopplerDeployer.RoleAlreadyAssigned.selector);

        vm.prank(owner);
        deployer.addDeployer(admin);
    }

    /// @notice Admin can revoke deployer role and emit the expected events.
    function test_removeDeployer_adminCanRevokeDeployerRole() public {
        _addAuthorizedDeployer();

        vm.expectEmit(true, true, false, false, address(deployer));
        emit RolesUpdated(authorizedDeployer, 0);
        vm.expectEmit(true, false, false, true, address(deployer));
        emit DeployerRemoved(admin, authorizedDeployer);

        vm.prank(admin);
        deployer.removeDeployer(authorizedDeployer);

        assertEq(deployer.rolesOf(authorizedDeployer), 0);
    }

    /// @notice Deployer removal rejects targets without only deployer role.
    function test_removeDeployer_revertIfTargetIsNotDeployer() public {
        _addAdmin();

        vm.expectRevert(DopplerDeployer.InvalidDeployer.selector);

        vm.prank(owner);
        deployer.removeDeployer(admin);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       SALT FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Generated salts are deployer-keyed with name and version entropy.
    function test_generateSalt_usesDeployerAddressAndNameVersionEntropy() public view {
        bytes32 salt = deployer.generateSalt("DopplerDeployer", 2);
        bytes32 expected = bytes32(uint256(uint160(address(deployer))) << 96)
            | bytes32(uint256(keccak256(abi.encode("DopplerDeployer", uint256(2)))) >> 168);

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

        vm.expectEmit(true, false, false, true, address(deployer));
        emit Deployed(owner, expected);

        vm.prank(owner);
        address deployed = deployer.deployCreate2(salt, initCode);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 42);
        assertEq(DeployableContract(deployed).constructorSender(), CREATEX);
    }

    /// @notice Deployer role can deploy with default salt and expected-address check.
    function test_deployCreate2_deployerRoleDeploysDefaultSaltToExpectedAddress() public {
        _addAuthorizedDeployer();

        bytes memory initCode = _deployableInitCode(43);
        bytes32 salt = deployer.generateSalt("Create2Expected", 1);
        address expected = deployer.computeCreate2Address(salt, keccak256(initCode));

        vm.prank(authorizedDeployer);
        address deployed = deployer.deployCreate2(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 43);
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

        vm.expectRevert(abi.encodeWithSelector(DopplerDeployer.AddressMismatch.selector, actual, wrongExpected));

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

    /// @notice Invalid Create2 salts revert from CreateX.
    function test_deployCreate2_revertInvalidSaltFromCreateX() public {
        bytes32 salt = _salt(address(deployer), 2, 0x1234);

        vm.expectRevert(abi.encodeWithSelector(ICreateX.InvalidSalt.selector, CREATEX));

        vm.prank(owner);
        deployer.deployCreate2(salt, _deployableInitCode(1));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CREATE3 DEPLOYMENT                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Owner can deploy with Create3 to the computed address.
    function test_deployCreate3_ownerDeploysToComputedAddress() public {
        bytes memory initCode = _deployableInitCode(45);
        bytes32 salt = deployer.generateSalt("Create3Owner", 1);
        address expected = deployer.computeCreate3Address(salt);

        vm.expectEmit(true, false, false, true, address(deployer));
        emit Deployed(owner, expected);

        vm.prank(owner);
        address deployed = deployer.deployCreate3(salt, initCode);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 45);
    }

    /// @notice Deployer role can deploy with Create3 and expected-address check.
    function test_deployCreate3_deployerRoleDeploysToExpectedAddress() public {
        _addAuthorizedDeployer();

        bytes memory initCode = _deployableInitCode(46);
        bytes32 salt = deployer.generateSalt("Create3Expected", 1);
        address expected = deployer.computeCreate3Address(salt);

        vm.prank(authorizedDeployer);
        address deployed = deployer.deployCreate3(salt, initCode, expected);

        assertEq(deployed, expected);
        assertEq(DeployableContract(deployed).value(), 46);
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

        vm.expectRevert(abi.encodeWithSelector(DopplerDeployer.AddressMismatch.selector, actual, wrongExpected));

        vm.prank(owner);
        deployer.deployCreate3(salt, initCode, wrongExpected);

        assertEq(actual.code.length, 0);
    }

    /// @notice Invalid Create3 salts revert from CreateX.
    function test_deployCreate3_revertInvalidSaltFromCreateX() public {
        vm.expectRevert(abi.encodeWithSelector(ICreateX.InvalidSalt.selector, CREATEX));

        vm.prank(owner);
        deployer.deployCreate3(_salt(address(deployer), 2, 0x1234), _deployableInitCode(1));
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

        vm.expectRevert(DopplerDeployer.ExecutionFailed.selector);

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

    /// @notice Batch execution rejects mismatched input array lengths.
    function test_execute_batchRevertArrayLengthMismatch() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](1);

        vm.expectRevert(DopplerDeployer.ArrayLengthsMismatch.selector);

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

        vm.expectRevert(abi.encodeWithSelector(DopplerDeployer.PaymentMismatch.selector, 3, 2));

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

        vm.expectRevert(DopplerDeployer.ExecutionFailed.selector);

        vm.prank(owner);
        deployer.execute(targets, values, data);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         TEST HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _addAdmin() internal {
        vm.prank(owner);
        deployer.addAdmin(admin);
    }

    function _addAuthorizedDeployer() internal {
        _addAdmin();

        vm.prank(admin);
        deployer.addDeployer(authorizedDeployer);
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
    address public immutable constructorSender;

    constructor(uint256 value_) payable {
        value = value_;
        constructorSender = msg.sender;
    }
}

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
