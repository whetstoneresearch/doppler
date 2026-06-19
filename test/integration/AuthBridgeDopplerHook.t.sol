// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { IERC1271 } from "permit2/src/interfaces/IERC1271.sol";
import { AuthBridgeData, AuthBridgeDopplerHook } from "src/dopplerHooks/AuthBridgeDopplerHook.sol";
import {
    AuthBridgeOracle,
    AuthBridgeOracle_AlreadyDisabled,
    AuthBridgeOracle_ExecutorMismatch,
    AuthBridgeOracle_InvalidToken,
    AuthBridgeOracle_NonceUsed,
    AuthBridgeOracle_NotDisableAuthority,
    LaneConfig
} from "src/implementations/authBridge/AuthBridgeOracle.sol";
import {
    AuthBridgeTransferExecutor,
    AuthBridgeTransferExecutor_AuthorizationDisabled
} from "src/implementations/authBridge/AuthBridgeTransferExecutor.sol";
import { AuthBridgeInitData, AuthSwap, AuthTransfer } from "src/interfaces/IAuthBridgeOracle.sol";

contract MockERC1271 is IERC1271 {
    bytes32 public allowedHash;

    function setAllowedHash(bytes32 hash) external {
        allowedHash = hash;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view override returns (bytes4) {
        return hash == allowedHash ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

contract AuthBridgeDopplerHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant UNSET_EXECUTOR = address(0);
    address internal constant TEST_ASSET = address(0xA55E7);
    address internal constant TEST_NUMERAIRE = address(0x1000);
    uint24 internal constant TEST_FEE = 0;
    int24 internal constant TEST_TICK_SPACING = 8;
    uint64 internal constant AUTH_WINDOW = 60;
    uint160 internal constant SQRT_PRICE_1_1_X96 = 1 << 96;
    uint256 internal constant USER_PRIVATE_KEY = 0x1234;
    uint256 internal constant AUTH_PRIVATE_KEY = 0x5678;
    uint256 internal constant USER_STARTING_BALANCE = 100 ether;
    int256 internal constant SWAP_AMOUNT_SPECIFIED = 1 ether;
    uint256 internal constant TRANSFER_AMOUNT = 3 ether;
    uint256 internal constant DISABLED_TRANSFER_AMOUNT = 1 ether;
    bytes2 internal constant EIP712_PREFIX = 0x1901;

    bytes32 internal constant AUTH_SWAP_TYPEHASH = keccak256(
        "AuthSwap(address user,address executor,address asset,bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,bytes32 nonce,uint64 deadline)"
    );
    bytes32 internal constant AUTH_TRANSFER_TYPEHASH = keccak256(
        "AuthTransfer(address token,address from,address to,uint256 amount,address executor,bytes32 nonce,uint64 deadline)"
    );

    address internal owner = makeAddr("owner");
    address internal initializer = makeAddr("initializer");
    address internal disableAuthority = makeAddr("disableAuthority");
    address internal relayer = makeAddr("relayer");
    address internal recipient = makeAddr("recipient");

    address internal user;
    address internal authSigner;

    AuthBridgeOracle internal oracle;
    AuthBridgeDopplerHook internal hook;
    AuthBridgeTransferExecutor internal transferExecutor;
    TestERC20 internal token;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        user = vm.addr(USER_PRIVATE_KEY);
        authSigner = vm.addr(AUTH_PRIVATE_KEY);

        oracle = new AuthBridgeOracle(owner);
        hook = new AuthBridgeDopplerHook(initializer, address(oracle));
        transferExecutor = new AuthBridgeTransferExecutor(address(oracle));
        token = new TestERC20(0);

        poolKey = PoolKey({
            currency0: Currency.wrap(TEST_NUMERAIRE),
            currency1: Currency.wrap(TEST_ASSET),
            fee: TEST_FEE,
            tickSpacing: TEST_TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        vm.startPrank(owner);
        oracle.setTrustedCaller(address(hook), true);
        oracle.setTrustedCaller(address(transferExecutor), true);
        vm.stopPrank();
    }

    function test_onInitialization_InitializesSwapLane() public {
        _initializeSwapLane();

        bytes32 lane = oracle.swapLane(poolId);
        LaneConfig memory config = _laneConfig(lane);
        assertEq(config.authSigner, authSigner);
        assertEq(config.disableAuthority, disableAuthority);
        assertTrue(config.initialized);
        assertFalse(config.disabled);
        assertEq(hook.poolAsset(poolId), TEST_ASSET);
    }

    function test_onSwap_ValidSignatures() public {
        _initializeSwapLane();

        IPoolManager.SwapParams memory params = _swapParams();
        bytes32 nonce = keccak256("swap nonce");
        bytes memory hookData = _swapHookData(user, relayer, nonce, _futureDeadline(), params);

        vm.prank(initializer);
        hook.onSwap(relayer, poolKey, params, _zeroDelta(), hookData);

        assertTrue(oracle.nonceUsed(oracle.swapLane(poolId), user, nonce));
    }

    function test_onSwap_ReplayReverts() public {
        _initializeSwapLane();

        IPoolManager.SwapParams memory params = _swapParams();
        bytes32 nonce = keccak256("replay nonce");
        bytes memory hookData = _swapHookData(user, relayer, nonce, _futureDeadline(), params);

        vm.prank(initializer);
        hook.onSwap(relayer, poolKey, params, _zeroDelta(), hookData);

        vm.expectRevert(
            abi.encodeWithSelector(AuthBridgeOracle_NonceUsed.selector, oracle.swapLane(poolId), user, nonce)
        );
        vm.prank(initializer);
        hook.onSwap(relayer, poolKey, params, _zeroDelta(), hookData);
    }

    function test_onSwap_ExecutorMismatchReverts() public {
        _initializeSwapLane();

        IPoolManager.SwapParams memory params = _swapParams();
        address expectedExecutor = makeAddr("expectedExecutor");
        bytes memory hookData =
            _swapHookData(user, expectedExecutor, keccak256("executor nonce"), _futureDeadline(), params);

        vm.expectRevert(abi.encodeWithSelector(AuthBridgeOracle_ExecutorMismatch.selector, expectedExecutor, relayer));
        vm.prank(initializer);
        hook.onSwap(relayer, poolKey, params, _zeroDelta(), hookData);
    }

    function test_onSwap_UnsetExecutorReverts() public {
        _initializeSwapLane();

        IPoolManager.SwapParams memory params = _swapParams();
        bytes memory hookData =
            _swapHookData(user, UNSET_EXECUTOR, keccak256("unset executor nonce"), _futureDeadline(), params);

        vm.expectRevert(abi.encodeWithSelector(AuthBridgeOracle_ExecutorMismatch.selector, UNSET_EXECUTOR, relayer));
        vm.prank(initializer);
        hook.onSwap(relayer, poolKey, params, _zeroDelta(), hookData);
    }

    function test_onSwap_DisabledLaneAllowsMissingHookData() public {
        _initializeSwapLane();

        vm.prank(disableAuthority);
        oracle.disableSwapAuthorization(poolId);

        vm.prank(initializer);
        hook.onSwap(relayer, poolKey, _swapParams(), _zeroDelta(), new bytes(0));
    }

    function test_disableSwapAuthorization_RevertsWhenNotDisableAuthority() public {
        _initializeSwapLane();

        bytes32 lane = oracle.swapLane(poolId);
        vm.expectRevert(abi.encodeWithSelector(AuthBridgeOracle_NotDisableAuthority.selector, lane, user));
        vm.prank(user);
        oracle.disableSwapAuthorization(poolId);
    }

    function test_disableSwapAuthorization_RevertsWhenAlreadyDisabled() public {
        _initializeSwapLane();

        vm.startPrank(disableAuthority);
        oracle.disableSwapAuthorization(poolId);
        vm.expectRevert(abi.encodeWithSelector(AuthBridgeOracle_AlreadyDisabled.selector, oracle.swapLane(poolId)));
        oracle.disableSwapAuthorization(poolId);
        vm.stopPrank();
    }

    function test_onSwap_ERC1271UserSignature() public {
        _initializeSwapLane();

        MockERC1271 contractUser = new MockERC1271();
        IPoolManager.SwapParams memory params = _swapParams();
        bytes32 nonce = keccak256("1271 nonce");
        uint64 deadline = _futureDeadline();
        bytes32 digest = _swapDigest(address(contractUser), relayer, nonce, deadline, params);
        contractUser.setAllowedHash(digest);

        (, bytes memory authSig) = _signDigest(digest);
        bytes memory hookData = abi.encode(
            AuthBridgeData({
                user: address(contractUser),
                executor: relayer,
                nonce: nonce,
                deadline: deadline,
                userSig: new bytes(0),
                authSig: authSig
            })
        );

        vm.prank(initializer);
        hook.onSwap(relayer, poolKey, params, _zeroDelta(), hookData);
        assertTrue(oracle.nonceUsed(oracle.swapLane(poolId), address(contractUser), nonce));
    }

    function test_transferWithAuthorization_ValidSignatures() public {
        _initializeTransferLane();
        token.mint(user, USER_STARTING_BALANCE);

        bytes32 nonce = keccak256("transfer nonce");
        AuthTransfer memory transferAuth = _transferAuth(TRANSFER_AMOUNT, nonce, _futureDeadline(), relayer);
        (bytes memory userSig, bytes memory authSig) = _transferSigs(transferAuth);

        vm.prank(user);
        token.approve(address(transferExecutor), TRANSFER_AMOUNT);

        vm.prank(relayer);
        transferExecutor.transferWithAuthorization(transferAuth, userSig, authSig);

        assertEq(token.balanceOf(user), USER_STARTING_BALANCE - TRANSFER_AMOUNT);
        assertEq(token.balanceOf(recipient), TRANSFER_AMOUNT);
        assertTrue(oracle.nonceUsed(oracle.transferLane(address(token)), user, nonce));
    }

    function test_transferWithAuthorization_DisabledLaneReverts() public {
        _initializeTransferLane();

        vm.prank(disableAuthority);
        oracle.disableTransferAuthorization(address(token));

        AuthTransfer memory transferAuth =
            _transferAuth(DISABLED_TRANSFER_AMOUNT, keccak256("disabled transfer nonce"), _futureDeadline(), relayer);
        (bytes memory userSig, bytes memory authSig) = _transferSigs(transferAuth);

        vm.expectRevert(
            abi.encodeWithSelector(AuthBridgeTransferExecutor_AuthorizationDisabled.selector, address(token))
        );
        vm.prank(relayer);
        transferExecutor.transferWithAuthorization(transferAuth, userSig, authSig);
    }

    function test_transferWithAuthorization_UnsetExecutorReverts() public {
        _initializeTransferLane();

        AuthTransfer memory transferAuth = _transferAuth(
            TRANSFER_AMOUNT, keccak256("unset transfer executor nonce"), _futureDeadline(), UNSET_EXECUTOR
        );
        (bytes memory userSig, bytes memory authSig) = _transferSigs(transferAuth);

        vm.expectRevert(abi.encodeWithSelector(AuthBridgeOracle_ExecutorMismatch.selector, UNSET_EXECUTOR, relayer));
        vm.prank(relayer);
        transferExecutor.transferWithAuthorization(transferAuth, userSig, authSig);
    }

    function test_initializeTransferAuthorization_RevertsWhenTokenZero() public {
        vm.expectRevert(AuthBridgeOracle_InvalidToken.selector);
        vm.prank(owner);
        oracle.initializeTransferAuthorization(address(0), authSigner, disableAuthority);
    }

    function _initializeSwapLane() internal {
        AuthBridgeInitData memory initData =
            AuthBridgeInitData({ authSigner: authSigner, disableAuthority: disableAuthority });
        vm.prank(initializer);
        hook.onInitialization(TEST_ASSET, poolKey, abi.encode(initData));
    }

    function _initializeTransferLane() internal {
        vm.prank(owner);
        oracle.initializeTransferAuthorization(address(token), authSigner, disableAuthority);
    }

    function _swapParams() internal pure returns (IPoolManager.SwapParams memory) {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: SWAP_AMOUNT_SPECIFIED, sqrtPriceLimitX96: SQRT_PRICE_1_1_X96
        });
        return params;
    }

    function _futureDeadline() internal view returns (uint64) {
        return uint64(block.timestamp + AUTH_WINDOW);
    }

    function _zeroDelta() internal pure returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    function _swapHookData(
        address user_,
        address executor,
        bytes32 nonce,
        uint64 deadline,
        IPoolManager.SwapParams memory params
    ) internal view returns (bytes memory) {
        bytes32 digest = _swapDigest(user_, executor, nonce, deadline, params);
        (bytes memory userSig, bytes memory authSig) = _signDigest(digest);
        return abi.encode(
            AuthBridgeData({
                user: user_, executor: executor, nonce: nonce, deadline: deadline, userSig: userSig, authSig: authSig
            })
        );
    }

    function _swapDigest(
        address user_,
        address executor,
        bytes32 nonce,
        uint64 deadline,
        IPoolManager.SwapParams memory params
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                AUTH_SWAP_TYPEHASH,
                user_,
                executor,
                TEST_ASSET,
                PoolId.unwrap(poolId),
                params.zeroForOne,
                params.amountSpecified,
                params.sqrtPriceLimitX96,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked(EIP712_PREFIX, oracle.DOMAIN_SEPARATOR(), structHash));
    }

    function _transferAuth(
        uint256 amount,
        bytes32 nonce,
        uint64 deadline,
        address executor
    ) internal view returns (AuthTransfer memory) {
        return AuthTransfer({
            token: address(token),
            from: user,
            to: recipient,
            amount: amount,
            executor: executor,
            nonce: nonce,
            deadline: deadline
        });
    }

    function _transferSigs(AuthTransfer memory transferAuth)
        internal
        view
        returns (bytes memory userSig, bytes memory authSig)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                AUTH_TRANSFER_TYPEHASH,
                transferAuth.token,
                transferAuth.from,
                transferAuth.to,
                transferAuth.amount,
                transferAuth.executor,
                transferAuth.nonce,
                transferAuth.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(EIP712_PREFIX, oracle.DOMAIN_SEPARATOR(), structHash));
        return _signDigest(digest);
    }

    function _signDigest(bytes32 digest) internal pure returns (bytes memory userSig, bytes memory authSig) {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(USER_PRIVATE_KEY, digest);
        userSig = abi.encodePacked(r1, s1, v1);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(AUTH_PRIVATE_KEY, digest);
        authSig = abi.encodePacked(r2, s2, v2);
    }

    function _laneConfig(bytes32 lane) internal view returns (LaneConfig memory config) {
        (config.authSigner, config.disableAuthority, config.initialized, config.disabled) = oracle.laneConfig(lane);
    }
}
