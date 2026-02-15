// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { SignatureVerification } from "permit2/src/libraries/SignatureVerification.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { IAuthBridgeOracle, AuthSwap } from "src/interfaces/IAuthBridgeOracle.sol";

error AuthBridgeOracle_OnlyHook();
error AuthBridgeOracle_NotInitialized(PoolId poolId);
error AuthBridgeOracle_AlreadyInitialized(PoolId poolId);
error AuthBridgeOracle_InvalidSigner();
error AuthBridgeOracle_ExecutorMismatch(address expected, address actual);
error AuthBridgeOracle_Expired(uint64 deadline, uint64 nowTs);
error AuthBridgeOracle_InvalidNonce(address user, uint64 expected, uint64 provided);

struct AuthBridgeOracleInitData {
    address platformSigner;
}

contract AuthBridgeOracle is IAuthBridgeOracle {
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private constant _HASHED_NAME = keccak256("AuthBridgeDopplerHook");
    bytes32 private constant _HASHED_VERSION = keccak256("1");
    bytes32 private constant _TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant AUTH_SWAP_TYPEHASH = keccak256(
        "AuthSwap(address user,address executor,bytes32 poolId,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,uint64 nonce,uint64 deadline)"
    );

    address public immutable HOOK;

    mapping(PoolId poolId => mapping(address user => uint64 nonce)) public nonces;
    mapping(PoolId poolId => address signer) public platformSigner;

    constructor(address hook) {
        HOOK = hook;

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
    }

    function initialize(PoolId poolId, address, bytes calldata data) external override {
        if (msg.sender != HOOK) revert AuthBridgeOracle_OnlyHook();
        if (platformSigner[poolId] != address(0)) revert AuthBridgeOracle_AlreadyInitialized(poolId);

        AuthBridgeOracleInitData memory initData = abi.decode(data, (AuthBridgeOracleInitData));
        if (initData.platformSigner == address(0)) revert AuthBridgeOracle_InvalidSigner();

        platformSigner[poolId] = initData.platformSigner;
    }

    function isAuthorized(
        AuthSwap calldata swap,
        address sender,
        bytes calldata userSig,
        bytes calldata platformSig
    ) external override returns (bool) {
        if (msg.sender != HOOK) revert AuthBridgeOracle_OnlyHook();

        PoolId poolId = PoolId.wrap(swap.poolId);
        address signer = platformSigner[poolId];
        if (signer == address(0)) revert AuthBridgeOracle_NotInitialized(poolId);

        if (swap.executor != address(0) && swap.executor != sender) {
            revert AuthBridgeOracle_ExecutorMismatch(swap.executor, sender);
        }
        if (block.timestamp > swap.deadline) {
            revert AuthBridgeOracle_Expired(swap.deadline, uint64(block.timestamp));
        }

        uint64 expectedNonce = nonces[poolId][swap.user];
        if (swap.nonce != expectedNonce) {
            revert AuthBridgeOracle_InvalidNonce(swap.user, expectedNonce, swap.nonce);
        }

        bytes32 structHash = keccak256(
            abi.encode(
                AUTH_SWAP_TYPEHASH,
                swap.user,
                swap.executor,
                swap.poolId,
                swap.zeroForOne,
                swap.amountSpecified,
                swap.sqrtPriceLimitX96,
                swap.nonce,
                swap.deadline
            )
        );
        bytes32 digest = _hashTypedData(structHash);

        SignatureVerification.verify(userSig, digest, swap.user);
        SignatureVerification.verify(platformSig, digest, signer);

        nonces[poolId][swap.user] = swap.nonce + 1;
        return true;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function _domainSeparator() internal view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID
            ? _CACHED_DOMAIN_SEPARATOR
            : _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
    }

    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), dataHash));
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 nameHash, bytes32 versionHash)
        private
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
    }
}
