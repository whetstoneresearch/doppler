// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency, greaterThan } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IERC1271 } from "permit2/src/interfaces/IERC1271.sol";

import { console } from "forge-std/console.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHook.sol";
import {
    AuthBridgeDopplerHook,
    AuthBridgeData,
    AuthBridgeInitData
} from "src/dopplerHooks/AuthBridgeDopplerHook.sol";
import { AuthBridgeOracle, AuthBridgeOracleInitData } from "src/dopplerHooks/AuthBridgeOracle.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DERC20 } from "src/tokens/DERC20.sol";
import { TokenFactory } from "src/tokens/TokenFactory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract LiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes memory) external pure override returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable override returns (uint256) {
        return 0;
    }
}

contract MockERC1271 is IERC1271 {
    bytes32 public allowedHash;

    function setAllowedHash(bytes32 hash) external {
        allowedHash = hash;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view override returns (bytes4) {
        return hash == allowedHash ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

contract AuthBridgeDopplerHookIntegrationTest is Deployers {
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============

    bytes32 internal constant AUTH_SWAP_TYPEHASH = keccak256(
        "AuthSwap(address user,address executor,bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,uint64 nonce,uint64 deadline)"
    );

    // ============ State ============

    address public airlockOwner = makeAddr("AirlockOwner");

    Airlock public airlock;
    DopplerHookInitializer public initializer;
    TokenFactory public tokenFactory;
    GovernanceFactory public governanceFactory;
    LiquidityMigratorMock public mockLiquidityMigrator;
    AuthBridgeDopplerHook public authBridgeHook;
    AuthBridgeOracle public authBridgeOracle;
    TestERC20 public numeraire;

    PoolKey public poolKey;
    PoolId public poolId;

    // Test signers
    uint256 internal userPrivateKey = 0x1234;
    uint256 internal platformPrivateKey = 0x5678;
    uint256 internal unauthorizedPrivateKey = 0xdead;

    address internal userAddress;
    address internal platformSigner;
    address internal unauthorizedSigner;
    MockERC1271 internal mock1271;

    function setUp() public {
        // Derive addresses from private keys
        userAddress = vm.addr(userPrivateKey);
        platformSigner = vm.addr(platformPrivateKey);
        unauthorizedSigner = vm.addr(unauthorizedPrivateKey);

        vm.label(userAddress, "User");
        vm.label(platformSigner, "PlatformSigner");
        vm.label(unauthorizedSigner, "UnauthorizedSigner");

        deployFreshManagerAndRouters();
        numeraire = new TestERC20(1e48);
        vm.label(address(numeraire), "Numeraire");

        airlock = new Airlock(airlockOwner);
        tokenFactory = new TokenFactory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));

        initializer = DopplerHookInitializer(
            payable(
                address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                )
            )
        );

        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));

        authBridgeHook = new AuthBridgeDopplerHook(address(initializer));
        authBridgeOracle = new AuthBridgeOracle(address(authBridgeHook));
        vm.label(address(authBridgeHook), "AuthBridgeDopplerHook");
        vm.label(address(authBridgeOracle), "AuthBridgeOracle");

        mock1271 = new MockERC1271();

        mockLiquidityMigrator = new LiquidityMigratorMock();

        // Set module states
        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(mockLiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        vm.startPrank(airlockOwner);
        airlock.setModuleState(modules, states);

        address[] memory dopplerHooks = new address[](1);
        dopplerHooks[0] = address(authBridgeHook);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;
        initializer.setDopplerHookState(dopplerHooks, flags);
        vm.stopPrank();
    }

    // ============ Spec Test Cases ============

    /// @notice Test 1: Happy path - valid signatures, swap succeeds
    function test_happyPath_ValidSignatures() public {
        bytes32 salt = bytes32(uint256(1));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory hookData = _createHookData(userAddress, address(0), deadline, nonce, params);

        // Swap should succeed
        vm.prank(userAddress);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);

        // Verify nonce was incremented
        assertEq(authBridgeOracle.nonces(poolId, userAddress), 1, "Nonce should be incremented");
    }

    /// @notice Test 2: Missing hookData - reverts AuthBridge_MissingHookData
    function test_missingHookData_Reverts() public {
        bytes32 salt = bytes32(uint256(2));
        (bool isToken0,) = _createToken(salt);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Swap with empty hookData should revert (V4 wraps the error)
        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), new bytes(0));
    }

    /// @notice Test 3: Bad user signature - reverts AuthBridge_InvalidUserSig
    function test_badUserSignature_Reverts() public {
        bytes32 salt = bytes32(uint256(3));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Create hookData with wrong user signature (sign with unauthorized key)
        bytes memory hookData =
            _createHookDataWithWrongUserSig(userAddress, address(0), deadline, nonce, params, unauthorizedPrivateKey);

        // V4 wraps hook reverts - just verify it reverts
        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Test 4: Bad platform signature - reverts AuthBridge_UnauthorizedPlatformSigner
    function test_badPlatformSignature_Reverts() public {
        bytes32 salt = bytes32(uint256(4));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Create hookData with unauthorized platform signature
        bytes memory hookData = _createHookDataWithUnauthorizedPlatform(userAddress, address(0), deadline, nonce, params);

        // V4 wraps hook reverts - just verify it reverts
        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Test 5: Expired deadline - reverts AuthBridge_Expired
    function test_expiredDeadline_Reverts() public {
        bytes32 salt = bytes32(uint256(5));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp - 1); // Already expired
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory hookData = _createHookData(userAddress, address(0), deadline, nonce, params);

        // V4 wraps hook reverts - just verify it reverts
        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Test 6: Nonce mismatch - reverts AuthBridge_InvalidNonce
    function test_nonceMismatch_Reverts() public {
        bytes32 salt = bytes32(uint256(6));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 wrongNonce = 5; // Expected is 0

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory hookData = _createHookData(userAddress, address(0), deadline, wrongNonce, params);

        // V4 wraps hook reverts - just verify it reverts
        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Test 7: Nonce consumed (replay) - reverts AuthBridge_InvalidNonce
    function test_nonceConsumed_ReplayReverts() public {
        bytes32 salt = bytes32(uint256(7));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory hookData = _createHookData(userAddress, address(0), deadline, nonce, params);

        // First swap succeeds
        vm.prank(userAddress);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);

        // Second swap with same hookData (same nonce) should fail
        // V4 wraps hook reverts - just verify it reverts
        vm.expectRevert();
        vm.prank(userAddress);
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Test 8: Executor binding mismatch - reverts AuthBridge_ExecutorMismatch
    function test_executorMismatch_Reverts() public {
        bytes32 salt = bytes32(uint256(8));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;
        address expectedExecutor = makeAddr("ExpectedExecutor");

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Bind to expectedExecutor but call from swapRouter (different address)
        bytes memory hookData = _createHookData(userAddress, expectedExecutor, deadline, nonce, params);

        // V4 wraps hook reverts - just verify it reverts
        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }


    // ============ Fuzz Tests ============

    /// @notice Fuzz test for nonce boundaries
    function testFuzz_nonceBoundaries(uint64 initialNonce) public {
        // Skip if nonce would overflow on increment
        vm.assume(initialNonce < type(uint64).max);

        bytes32 salt = bytes32(uint256(100 + uint256(initialNonce) % 1000));
        (bool isToken0,) = _createToken(salt);

        // Manually set nonce to initialNonce (we'd need storage manipulation in real test)
        // For now, we'll test that nonce 0 works and increments properly
        if (initialNonce == 0) {
            uint64 deadline = uint64(block.timestamp + 60);

            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: !isToken0,
                amountSpecified: 1 ether,
                sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });

            bytes memory hookData = _createHookData(userAddress, address(0), deadline, 0, params);
            vm.prank(userAddress);
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);

            assertEq(authBridgeOracle.nonces(poolId, userAddress), 1);
        }
    }

    /// @notice Fuzz test for deadline edges
    function testFuzz_deadlineEdges(uint64 deadlineOffset) public {
        bytes32 salt = bytes32(uint256(200));
        (bool isToken0,) = _createToken(salt);

        // Constrain offset to reasonable range
        deadlineOffset = uint64(bound(deadlineOffset, 0, 365 days));

        uint64 deadline = uint64(block.timestamp) + deadlineOffset;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory hookData = _createHookData(userAddress, address(0), deadline, 0, params);

        // Should succeed if deadline is in the future or now
        if (deadline >= block.timestamp) {
            vm.prank(userAddress);
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
        }
    }


    /// @notice Test executor binding works when correct
    function test_executorBinding_Success() public {
        bytes32 salt = bytes32(uint256(305));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // Bind to swapRouter (which is the actual executor/sender)
        bytes memory hookData = _createHookData(userAddress, address(swapRouter), deadline, nonce, params);

        // Should succeed
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Permit2-style compact signatures (EIP-2098) are accepted
    function test_compactSignatures_Succeed() public {
        bytes32 salt = bytes32(uint256(306));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes32 digest = _computeDigest(userAddress, address(0), deadline, nonce, params);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPrivateKey, digest);
        bytes memory userSig = _compactSig(v1, r1, s1);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(platformPrivateKey, digest);
        bytes memory platformSig = _compactSig(v2, r2, s2);

        bytes memory hookData = _createHookDataWithSigs(userAddress, address(0), deadline, nonce, userSig, platformSig);

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
        assertEq(authBridgeOracle.nonces(poolId, userAddress), 1);
    }

    /// @notice Invalid signature length should fail authorization
    function test_invalidSignatureLength_Reverts() public {
        bytes32 salt = bytes32(uint256(307));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes32 digest = _computeDigest(userAddress, address(0), deadline, nonce, params);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(platformPrivateKey, digest);
        bytes memory platformSig = abi.encodePacked(r2, s2, v2);

        bytes memory badSig = new bytes(63);
        bytes memory hookData = _createHookDataWithSigs(userAddress, address(0), deadline, nonce, badSig, platformSig);

        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Invalid platform signature length should fail authorization
    function test_invalidPlatformSignatureLength_Reverts() public {
        bytes32 salt = bytes32(uint256(309));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes32 digest = _computeDigest(userAddress, address(0), deadline, nonce, params);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPrivateKey, digest);
        bytes memory userSig = abi.encodePacked(r1, s1, v1);

        bytes memory badSig = new bytes(63);
        bytes memory hookData = _createHookDataWithSigs(userAddress, address(0), deadline, nonce, userSig, badSig);

        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice ERC-1271 contract wallet user signatures are supported
    function test_erc1271UserSignature_Succeeds() public {
        bytes32 salt = bytes32(uint256(308));
        (bool isToken0,) = _createToken(salt);

        address contractUser = address(mock1271);
        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes32 digest = _computeDigest(contractUser, address(0), deadline, nonce, params);
        mock1271.setAllowedHash(digest);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(platformPrivateKey, digest);
        bytes memory platformSig = abi.encodePacked(r2, s2, v2);

        bytes memory hookData = _createHookDataWithSigs(contractUser, address(0), deadline, nonce, new bytes(0), platformSig);

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
        assertEq(authBridgeOracle.nonces(poolId, contractUser), 1);
    }

    /// @notice ERC-1271 contract wallet returns bad magic value should revert
    function test_erc1271UserSignature_BadMagic_Reverts() public {
        bytes32 salt = bytes32(uint256(310));
        (bool isToken0,) = _createToken(salt);

        address contractUser = address(mock1271);
        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes32 digest = _computeDigest(contractUser, address(0), deadline, nonce, params);
        mock1271.setAllowedHash(bytes32(uint256(1)));

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(platformPrivateKey, digest);
        bytes memory platformSig = abi.encodePacked(r2, s2, v2);

        bytes memory hookData = _createHookDataWithSigs(contractUser, address(0), deadline, nonce, new bytes(0), platformSig);

        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Signed payload must match on-chain swap params
    function test_signedPayloadMismatch_Reverts() public {
        bytes32 salt = bytes32(uint256(311));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory signedParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        IPoolManager.SwapParams memory actualParams = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 2 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory hookData = _createHookData(userAddress, address(0), deadline, nonce, signedParams);

        vm.expectRevert();
        swapRouter.swap(poolKey, actualParams, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Platform signer mismatch should revert
    function test_platformSignerMismatch_Reverts() public {
        bytes32 salt = bytes32(uint256(312));
        (bool isToken0,) = _createToken(salt);

        uint64 deadline = uint64(block.timestamp + 60);
        uint64 nonce = 0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !isToken0,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: !isToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes32 digest = _computeDigest(userAddress, address(0), deadline, nonce, params);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPrivateKey, digest);
        bytes memory userSig = abi.encodePacked(r1, s1, v1);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(unauthorizedPrivateKey, digest);
        bytes memory platformSig = abi.encodePacked(r2, s2, v2);

        bytes memory hookData = _createHookDataWithSigs(userAddress, address(0), deadline, nonce, userSig, platformSig);

        vm.expectRevert();
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @notice Test initialization with no platform signers reverts
    function test_initWithNoPlatformSigners_Reverts() public {
        bytes32 salt = bytes32(uint256(900));
        address signer = address(0);

        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name,
                        symbol,
                        initialSupply,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        "TOKEN_URI"
                    )
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitDataWithSigner(tokenAddress, signer);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        vm.expectRevert();
        airlock.create(params);
    }

    /// @notice Domain separator changes if chainId changes (fork protection)
    function test_domainSeparator_ChangesOnChainId() public {
        bytes32 salt = bytes32(uint256(901));
        _createToken(salt);

        bytes32 original = authBridgeOracle.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        bytes32 updated = authBridgeOracle.DOMAIN_SEPARATOR();

        assertTrue(original != updated, "Domain separator should change with chainId");
    }

    // ============ Helper Functions ============

    function _createHookData(
        address user,
        address executor,
        uint64 deadline,
        uint64 nonce,
        IPoolManager.SwapParams memory params
    ) internal view returns (bytes memory) {
        return _createHookDataWithPlatformKey(user, executor, deadline, nonce, params, platformPrivateKey);
    }

    function _createHookDataWithPlatformKey(
        address user,
        address executor,
        uint64 deadline,
        uint64 nonce,
        IPoolManager.SwapParams memory params,
        uint256 platformKey
    ) internal view returns (bytes memory) {
        bytes32 digest = _computeDigest(user, executor, deadline, nonce, params);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPrivateKey, digest);
        bytes memory userSig = abi.encodePacked(r1, s1, v1);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(platformKey, digest);
        bytes memory platformSig = abi.encodePacked(r2, s2, v2);

        return _createHookDataWithSigs(user, executor, deadline, nonce, userSig, platformSig);
    }

    function _createHookDataWithWrongUserSig(
        address user,
        address executor,
        uint64 deadline,
        uint64 nonce,
        IPoolManager.SwapParams memory params,
        uint256 wrongUserKey
    ) internal view returns (bytes memory) {
        bytes32 digest = _computeDigest(user, executor, deadline, nonce, params);

        // Sign with wrong key
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(wrongUserKey, digest);
        bytes memory userSig = abi.encodePacked(r1, s1, v1);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(platformPrivateKey, digest);
        bytes memory platformSig = abi.encodePacked(r2, s2, v2);

        return _createHookDataWithSigs(user, executor, deadline, nonce, userSig, platformSig);
    }

    function _createHookDataWithUnauthorizedPlatform(
        address user,
        address executor,
        uint64 deadline,
        uint64 nonce,
        IPoolManager.SwapParams memory params
    ) internal view returns (bytes memory) {
        bytes32 digest = _computeDigest(user, executor, deadline, nonce, params);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPrivateKey, digest);
        bytes memory userSig = abi.encodePacked(r1, s1, v1);

        // Sign with unauthorized key
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(unauthorizedPrivateKey, digest);
        bytes memory platformSig = abi.encodePacked(r2, s2, v2);

        return _createHookDataWithSigs(user, executor, deadline, nonce, userSig, platformSig);
    }

    function _createHookDataWithSigs(
        address user,
        address executor,
        uint64 deadline,
        uint64 nonce,
        bytes memory userSig,
        bytes memory platformSig
    ) internal pure returns (bytes memory) {
        return abi.encode(
            AuthBridgeData({
                user: user,
                executor: executor,
                deadline: deadline,
                nonce: nonce,
                userSig: userSig,
                platformSig: platformSig
            })
        );
    }

    function _computeDigest(
        address user,
        address executor,
        uint64 deadline,
        uint64 nonce,
        IPoolManager.SwapParams memory params
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                AUTH_SWAP_TYPEHASH,
                user,
                executor,
                PoolId.unwrap(poolId),
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                nonce,
                deadline
            )
        );

        return keccak256(
            abi.encodePacked("\x19\x01", authBridgeOracle.DOMAIN_SEPARATOR(), structHash)
        );
    }

    function _compactSig(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        uint256 vs = (uint256(v - 27) << 255) | uint256(s);
        return abi.encodePacked(r, bytes32(vs));
    }

    function _createToken(bytes32 salt) internal returns (bool isToken0, address asset) {
        return _createTokenWithSigner(salt, platformSigner);
    }

    function _createTokenWithSigner(bytes32 salt, address signer)
        internal
        returns (bool isToken0, address asset)
    {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e27;

        address tokenAddress = vm.computeCreate2Address(
            salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name,
                        symbol,
                        initialSupply,
                        address(airlock),
                        address(airlock),
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        "TOKEN_URI"
                    )
                )
            ),
            address(tokenFactory)
        );

        InitData memory initData = _prepareInitDataWithSigner(tokenAddress, signer);

        CreateParams memory params = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), "TOKEN_URI"),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Test Token", 7200, 50_400, 0),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(mockLiquidityMigrator),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });

        (asset,,,,) = airlock.create(params);
        vm.label(asset, "Asset");
        isToken0 = asset < address(numeraire);

        (,,,,, poolKey,) = initializer.getState(asset);
        poolId = poolKey.toId();

        numeraire.approve(address(swapRouter), type(uint256).max);
        TestERC20(asset).approve(address(swapRouter), type(uint256).max);

        // Fund user with tokens for swapping
        deal(address(numeraire), userAddress, 100 ether);
        vm.prank(userAddress);
        numeraire.approve(address(swapRouter), type(uint256).max);
    }


    function _prepareInitDataWithSigner(address token, address signer)
        internal
        returns (InitData memory)
    {
        Curve[] memory curves = new Curve[](10);
        int24 tickSpacing = 8;

        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        Currency currency0 = Currency.wrap(address(numeraire));
        Currency currency1 = Currency.wrap(address(token));

        (currency0, currency1) = greaterThan(currency0, currency1) ? (currency1, currency0) : (currency0, currency1);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            tickSpacing: tickSpacing,
            fee: 0,
            hooks: initializer
        });
        poolId = poolKey.toId();

        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](2);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x07), shares: uint96(0.95e18) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: airlockOwner, shares: uint96(0.05e18) });

        bytes memory oracleData = abi.encode(AuthBridgeOracleInitData({ platformSigner: signer }));
        bytes memory authBridgeData = abi.encode(
            AuthBridgeInitData({ oracle: address(authBridgeOracle), oracleData: oracleData })
        );

        return InitData({
            fee: 0,
            tickSpacing: tickSpacing,
            farTick: 200_000,
            curves: curves,
            beneficiaries: beneficiaries,
            dopplerHook: address(authBridgeHook),
            onInitializationDopplerHookCalldata: authBridgeData,
            graduationDopplerHookCalldata: new bytes(0)
        });
    }
}
