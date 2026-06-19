// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { PoolId } from "@v4-core/types/PoolId.sol";
import { SignatureVerification } from "permit2/src/libraries/SignatureVerification.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { AuthSwap, AuthTransfer, IAuthBridgeOracle } from "src/interfaces/IAuthBridgeOracle.sol";

/// @notice Thrown when a caller is not trusted to use authorizations.
error AuthBridgeOracle_NotTrustedCaller();

/// @notice Thrown when an authorization lane has not been initialized.
error AuthBridgeOracle_NotInitialized(bytes32 lane);

/// @notice Thrown when an authorization lane is initialized more than once.
error AuthBridgeOracle_AlreadyInitialized(bytes32 lane);

/// @notice Thrown when the constructor owner is zero.
error AuthBridgeOracle_InvalidOwner();

/// @notice Thrown when an auth signer is zero.
error AuthBridgeOracle_InvalidAuthSigner();

/// @notice Thrown when a disable authority is zero.
error AuthBridgeOracle_InvalidDisableAuthority();

/// @notice Thrown when a transfer lane is initialized for the zero address.
error AuthBridgeOracle_InvalidToken();

/// @notice Thrown when a caller is not the disable authority for a lane.
error AuthBridgeOracle_NotDisableAuthority(bytes32 lane, address caller);

/// @notice Thrown when authorization is attempted after a lane has been disabled.
error AuthBridgeOracle_AuthorizationDisabled(bytes32 lane);

/// @notice Thrown when a disabled lane is disabled again.
error AuthBridgeOracle_AlreadyDisabled(bytes32 lane);

/// @notice Thrown when an authorization is bound to a different executor.
error AuthBridgeOracle_ExecutorMismatch(address expected, address actual);

/// @notice Thrown when an authorization is past its deadline.
error AuthBridgeOracle_Expired(uint64 deadline, uint64 nowTs);

/// @notice Thrown when a nonce has already been consumed for a user and lane.
error AuthBridgeOracle_NonceUsed(bytes32 lane, address user, bytes32 nonce);

/// @notice Authorization settings for either one swap pool or one transfer token.
struct LaneConfig {
    /// @notice Signer that co-signs authorized actions.
    address authSigner;

    /// @notice Address allowed to permanently disable this lane.
    address disableAuthority;

    /// @notice True once this lane has been configured.
    bool initialized;

    /// @notice True once the disable authority has permanently disabled authorization.
    bool disabled;
}

/**
 * @title Auth-Bridge Oracle
 * @author Whetstone Research
 * @custom:security-contact security@whetstone.cc
 * @notice Shared Auth Bridge authorizer for Doppler swaps and authorized token transfers.
 * @dev A lane is the smallest authorization unit: one pool for swaps or one token for transfers.
 */
contract AuthBridgeOracle is IAuthBridgeOracle, Ownable {
    /// @notice Domain name used for all Auth Bridge signatures.
    string public constant EIP712_NAME = "AuthBridge";

    /// @notice Domain version used for all Auth Bridge signatures.
    string public constant EIP712_VERSION = "1";

    /// @notice Lane seed for pool-scoped swap authorization.
    bytes32 public constant SWAP_LANE_SEED = keccak256("AUTH_BRIDGE_SWAP");

    /// @notice Lane seed for token-scoped transfer authorization.
    bytes32 public constant TRANSFER_LANE_SEED = keccak256("AUTH_BRIDGE_TRANSFER");

    /// @notice EIP-712 type hash for `AuthSwap`.
    bytes32 internal constant AUTH_SWAP_TYPEHASH = keccak256(
        "AuthSwap(address user,address executor,address asset,bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,bytes32 nonce,uint64 deadline)"
    );

    /// @notice EIP-712 type hash for `AuthTransfer`.
    bytes32 internal constant AUTH_TRANSFER_TYPEHASH = keccak256(
        "AuthTransfer(address token,address from,address to,uint256 amount,address executor,bytes32 nonce,uint64 deadline)"
    );

    bytes2 private constant _EIP712_DIGEST_PREFIX = 0x1901;
    bytes32 private constant _EIP712_NAME_HASH = keccak256(bytes(EIP712_NAME));
    bytes32 private constant _EIP712_VERSION_HASH = keccak256(bytes(EIP712_VERSION));
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    /// @notice Lane config by lane id.
    mapping(bytes32 lane => LaneConfig config) public laneConfig;

    /// @notice Trusted hooks/routes that may use authorizations.
    mapping(address caller => bool trusted) public trustedCaller;

    /// @notice Consumed unordered nonces keyed by lane, user, and nonce.
    mapping(bytes32 lane => mapping(address user => mapping(bytes32 nonce => bool used))) public nonceUsed;

    /// @notice Emitted when an authorization lane is initialized.
    event AuthBridgeLaneInitialized(bytes32 indexed lane, address indexed authSigner, address indexed disableAuthority);

    /// @notice Emitted when a hook or route is trusted or untrusted.
    event AuthBridgeTrustedCallerSet(address indexed caller, bool trusted);

    /// @notice Emitted when a disable authority permanently disables a lane.
    event AuthBridgeAuthorizationDisabled(bytes32 indexed lane, address indexed disableAuthority);

    modifier onlyTrustedCaller() {
        if (!trustedCaller[msg.sender]) revert AuthBridgeOracle_NotTrustedCaller();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert AuthBridgeOracle_InvalidOwner();
        _initializeOwner(owner_);

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @inheritdoc IAuthBridgeOracle
    function initializeSwapAuthorization(
        PoolId poolId,
        address authSigner,
        address disableAuthority
    ) external override onlyTrustedCaller {
        _initializeLane(_swapLane(poolId), authSigner, disableAuthority);
    }

    /// @inheritdoc IAuthBridgeOracle
    function initializeTransferAuthorization(
        address token,
        address authSigner,
        address disableAuthority
    ) external override onlyOwner {
        if (token == address(0)) revert AuthBridgeOracle_InvalidToken();
        _initializeLane(_transferLane(token), authSigner, disableAuthority);
    }

    /// @inheritdoc IAuthBridgeOracle
    function setTrustedCaller(address caller, bool trusted) external override onlyOwner {
        trustedCaller[caller] = trusted;
        emit AuthBridgeTrustedCallerSet(caller, trusted);
    }

    /// @inheritdoc IAuthBridgeOracle
    function authorizeSwap(
        AuthSwap calldata swapAuth,
        address sender,
        bytes calldata userSig,
        bytes calldata authSig
    ) external override onlyTrustedCaller {
        bytes32 lane = _swapLane(PoolId.wrap(swapAuth.poolId));
        LaneConfig memory config = _requireEnabledLane(lane);

        _checkExecutor(swapAuth.executor, sender);
        _checkDeadline(swapAuth.deadline);
        _consumeNonce(lane, swapAuth.user, swapAuth.nonce);

        bytes32 digest = _hashTypedData(_hashAuthSwap(swapAuth));
        SignatureVerification.verify(userSig, digest, swapAuth.user);
        SignatureVerification.verify(authSig, digest, config.authSigner);
    }

    /// @inheritdoc IAuthBridgeOracle
    function authorizeTransfer(
        AuthTransfer calldata transferAuth,
        address sender,
        bytes calldata userSig,
        bytes calldata authSig
    ) external override onlyTrustedCaller {
        bytes32 lane = _transferLane(transferAuth.token);
        LaneConfig memory config = _requireEnabledLane(lane);

        _checkExecutor(transferAuth.executor, sender);
        _checkDeadline(transferAuth.deadline);
        _consumeNonce(lane, transferAuth.from, transferAuth.nonce);

        bytes32 digest = _hashTypedData(_hashAuthTransfer(transferAuth));
        SignatureVerification.verify(userSig, digest, transferAuth.from);
        SignatureVerification.verify(authSig, digest, config.authSigner);
    }

    /// @inheritdoc IAuthBridgeOracle
    function disableSwapAuthorization(PoolId poolId) external override {
        _disableLane(_swapLane(poolId));
    }

    /// @inheritdoc IAuthBridgeOracle
    function disableTransferAuthorization(address token) external override {
        _disableLane(_transferLane(token));
    }

    /// @inheritdoc IAuthBridgeOracle
    function isSwapAuthorizationDisabled(PoolId poolId) external view override returns (bool) {
        return laneConfig[_swapLane(poolId)].disabled;
    }

    /// @inheritdoc IAuthBridgeOracle
    function isTransferAuthorizationDisabled(address token) external view override returns (bool) {
        return laneConfig[_transferLane(token)].disabled;
    }

    /// @notice Current EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @notice Returns the lane id for pool swap authorization.
    function swapLane(PoolId poolId) external pure returns (bytes32) {
        return _swapLane(poolId);
    }

    /// @notice Returns the lane id for token transfer authorization.
    function transferLane(address token) external pure returns (bytes32) {
        return _transferLane(token);
    }

    function _initializeLane(bytes32 lane, address authSigner, address disableAuthority) internal {
        if (laneConfig[lane].initialized) revert AuthBridgeOracle_AlreadyInitialized(lane);
        if (authSigner == address(0)) revert AuthBridgeOracle_InvalidAuthSigner();
        if (disableAuthority == address(0)) revert AuthBridgeOracle_InvalidDisableAuthority();

        laneConfig[lane] = LaneConfig({
            authSigner: authSigner, disableAuthority: disableAuthority, initialized: true, disabled: false
        });
        emit AuthBridgeLaneInitialized(lane, authSigner, disableAuthority);
    }

    function _requireEnabledLane(bytes32 lane) internal view returns (LaneConfig memory config) {
        config = laneConfig[lane];
        if (!config.initialized) revert AuthBridgeOracle_NotInitialized(lane);
        if (config.disabled) revert AuthBridgeOracle_AuthorizationDisabled(lane);
    }

    function _disableLane(bytes32 lane) internal {
        LaneConfig storage config = laneConfig[lane];
        if (!config.initialized) revert AuthBridgeOracle_NotInitialized(lane);
        if (config.disabled) revert AuthBridgeOracle_AlreadyDisabled(lane);
        if (msg.sender != config.disableAuthority) revert AuthBridgeOracle_NotDisableAuthority(lane, msg.sender);

        config.disabled = true;
        emit AuthBridgeAuthorizationDisabled(lane, msg.sender);
    }

    function _checkExecutor(address expected, address actual) internal pure {
        if (expected != actual) {
            revert AuthBridgeOracle_ExecutorMismatch(expected, actual);
        }
    }

    function _checkDeadline(uint64 deadline) internal view {
        if (block.timestamp > deadline) {
            revert AuthBridgeOracle_Expired(deadline, uint64(block.timestamp));
        }
    }

    function _consumeNonce(bytes32 lane, address user, bytes32 nonce) internal {
        if (nonceUsed[lane][user][nonce]) revert AuthBridgeOracle_NonceUsed(lane, user, nonce);
        nonceUsed[lane][user][nonce] = true;
    }

    function _hashAuthSwap(AuthSwap calldata swapAuth) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                AUTH_SWAP_TYPEHASH,
                swapAuth.user,
                swapAuth.executor,
                swapAuth.asset,
                swapAuth.poolId,
                swapAuth.zeroForOne,
                swapAuth.amountSpecified,
                swapAuth.sqrtPriceLimitX96,
                swapAuth.nonce,
                swapAuth.deadline
            )
        );
    }

    function _hashAuthTransfer(AuthTransfer calldata transferAuth) internal pure returns (bytes32) {
        return keccak256(
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
    }

    function _swapLane(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(SWAP_LANE_SEED, PoolId.unwrap(poolId)));
    }

    function _transferLane(address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(TRANSFER_LANE_SEED, token));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(_EIP712_DIGEST_PREFIX, _domainSeparator(), dataHash));
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }
}
