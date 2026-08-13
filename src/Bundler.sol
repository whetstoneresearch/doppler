// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Airlock, CreateParams } from "src/Airlock.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";

/// @notice Internal revert payload used to roll back a simulated swap.
error SwapQuote(uint128 amountOut);

/// @notice Internal revert payload used to roll back a simulated bundle and return its result.
error BundleQuote(address asset, PoolKey poolKey, address governance, address timelock, uint128 amountOut);

/// @notice Thrown when the initialized pool does not contain the created asset and configured numeraire.
error InvalidPool();

/// @notice Thrown when a simulation helper is called by any address other than this contract.
error SenderNotSelf();

/// @notice Thrown when a constructor address is zero.
error InvalidAddress();

/// @notice Thrown when the asset recipient is the zero address.
error InvalidRecipient();

/// @notice Thrown when an asset has no tokens available to claim.
error NoClaimableAmount();

/// @notice Thrown when a restricted vesting position is claimed by anyone other than its recipient.
error SenderNotRecipient();

/// @notice Thrown when native ETH is supplied for an ERC20 numeraire or does not match the exact input amount.
error InvalidNativeValue();

/// @notice Thrown when the PoolManager callback is invoked by any other address.
error SenderNotPoolManager();

/// @notice Thrown when the exact input amount is zero.
error ExactInputAmountZero();

/// @notice Thrown when a vesting position already exists for an asset.
error VestingAlreadyExists(address asset);

/// @notice Thrown when the cliff exceeds the vesting duration.
error InvalidVestingSchedule();

/// @notice Thrown when the pool does not consume the requested exact input amount.
error ExactInputNotFullySpent(uint256 expected, uint256 actual);

/// @notice Thrown when a simulation unexpectedly completes without returning a quote by reverting.
error UnexpectedSimulationSuccess();

/// @notice Emitted after a market is created and its initial asset purchase completes.
event Bundled(address indexed recipient, uint128 amountIn, uint128 amountOut, PoolKey poolKey);

/// @notice Emitted when purchased assets are placed in vesting.
event VestingCreated(
    address indexed asset,
    address indexed recipient,
    bool permissionlessClaim,
    uint128 totalAmount,
    uint64 start,
    uint64 cliffDuration,
    uint64 vestingDuration
);

/// @notice Emitted when vested assets are claimed for their recipient.
event VestingReleased(address indexed asset, address indexed recipient, uint128 amount);

/**
 * @title Doppler Bundler
 * @author Whetstone
 * @custom:security-contact security@whetstone.cc
 * @notice Atomically creates a Doppler market, buys its asset, and optionally vests the purchased amount.
 */
contract Bundler is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    /**
     * @notice Data passed through the PoolManager unlock callback for a bundled swap.
     * @param poolKey Key identifying the pool used for the swap.
     * @param zeroForOne Whether the swap exchanges currency0 for currency1.
     * @param exactAmountIn Exact amount of numeraire to spend.
     * @param payer Address funding the swap input.
     * @param recipient Address receiving the swap output.
     * @param simulate Whether the callback should return its result by reverting.
     */
    struct SwapCallbackData {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmountIn;
        address payer;
        address recipient;
        bool simulate;
    }

    /**
     * @notice Market creation data needed to execute the bundled swap.
     * @param asset Address of the created asset.
     * @param governance Address of the created governance contract.
     * @param timelock Address of the created timelock contract.
     * @param poolKey Key identifying the created pool.
     * @param zeroForOne Whether buying the asset exchanges currency0 for currency1.
     */
    struct BundleResult {
        address asset;
        address governance;
        address timelock;
        PoolKey poolKey;
        bool zeroForOne;
    }

    /**
     * @notice Optional vesting configuration for a bundled asset purchase.
     * @param permissionlessClaim Whether anyone may trigger claims for the recipient.
     * @param vestingDuration Seconds from creation until the entire purchase is vested, or zero to disable vesting.
     * @param cliffDuration Seconds from creation before vested assets become claimable.
     */
    struct VestingParams {
        bool permissionlessClaim;
        uint64 vestingDuration;
        uint64 cliffDuration;
    }

    /**
     * @notice Vesting position for an asset purchased through this Bundler.
     * @param recipient Address that receives claimed assets.
     * @param permissionlessClaim Whether anyone may trigger claims for the recipient.
     * @param start Timestamp from which vesting accrues.
     * @param cliffDuration Seconds after `start` before any assets are claimable.
     * @param vestingDuration Seconds after `start` when all assets are vested.
     * @param totalAmount Total amount of assets held in vesting.
     * @param claimedAmount Amount already claimed for the recipient.
     */
    struct Vesting {
        address recipient;
        bool permissionlessClaim;
        uint64 start;
        uint64 cliffDuration;
        uint64 vestingDuration;
        uint128 totalAmount;
        uint128 claimedAmount;
    }

    /// @notice Airlock used to create markets.
    Airlock public immutable airlock;

    /// @notice Uniswap V4 PoolManager used by Doppler pools.
    IPoolManager public immutable poolManager;

    /// @notice Vesting position for each bundled asset.
    mapping(address asset => Vesting vesting) public vestingOf;

    constructor(Airlock airlock_, IPoolManager poolManager_) {
        if (address(airlock_) == address(0) || address(poolManager_) == address(0)) revert InvalidAddress();
        airlock = airlock_;
        poolManager = poolManager_;
    }

    /**
     * @notice Creates a market and buys its asset with an exact amount of the configured numeraire.
     * @dev Native numeraires require `msg.value == exactAmountIn`. ERC20 numeraires require an approval for this
     *      contract. A zero `vestingData.vestingDuration` transfers the purchased asset directly to `recipient`;
     *      otherwise this contract holds the asset until it is claimed according to the configured vesting schedule.
     * @param createData Creation data passed to Airlock.
     * @param vestingData Optional vesting configuration for the purchased asset.
     * @param exactAmountIn Exact amount of numeraire spent on the asset purchase.
     * @param recipient Address that receives the purchased asset directly or through vesting claims.
     * @return asset Address of the created asset.
     * @return poolKey Key identifying the created Uniswap V4 pool.
     * @return governance Address of the created governance contract.
     * @return timelock Address of the created timelock contract.
     * @return amountOut Amount of the created asset purchased after hook fees.
     */
    function bundle(
        CreateParams calldata createData,
        VestingParams calldata vestingData,
        uint128 exactAmountIn,
        address recipient
    )
        external
        payable
        returns (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut)
    {
        if (exactAmountIn == 0) {
            revert ExactInputAmountZero();
        }
        if (recipient == address(0)) revert InvalidRecipient();
        if (vestingData.cliffDuration > vestingData.vestingDuration) revert InvalidVestingSchedule();

        bool nativeNumeraire = createData.numeraire == address(0);
        if (nativeNumeraire ? msg.value != exactAmountIn : msg.value != 0) revert InvalidNativeValue();

        BundleResult memory result = _createBundle(createData);

        bool vestingEnabled = vestingData.vestingDuration != 0;
        if (vestingEnabled && vestingOf[result.asset].recipient != address(0)) {
            revert VestingAlreadyExists(result.asset);
        }

        bytes memory swapResult = poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    poolKey: result.poolKey,
                    zeroForOne: result.zeroForOne,
                    exactAmountIn: exactAmountIn,
                    payer: msg.sender,
                    recipient: vestingEnabled ? address(this) : recipient,
                    simulate: false
                })
            )
        );

        amountOut = abi.decode(swapResult, (uint128));
        if (vestingEnabled) {
            uint64 start = uint64(block.timestamp);
            vestingOf[result.asset] = Vesting({
                recipient: recipient,
                permissionlessClaim: vestingData.permissionlessClaim,
                start: start,
                cliffDuration: vestingData.cliffDuration,
                vestingDuration: vestingData.vestingDuration,
                totalAmount: amountOut,
                claimedAmount: 0
            });
            emit VestingCreated(
                result.asset,
                recipient,
                vestingData.permissionlessClaim,
                amountOut,
                start,
                vestingData.cliffDuration,
                vestingData.vestingDuration
            );
        }

        emit Bundled(recipient, exactAmountIn, amountOut, result.poolKey);
        return (result.asset, result.poolKey, result.governance, result.timelock, amountOut);
    }

    /**
     * @notice Returns the amount currently claimable from an asset's vesting position.
     * @param asset Address of the vested asset.
     * @return amount Amount currently claimable by the position's recipient.
     */
    function claimable(address asset) public view returns (uint256 amount) {
        Vesting memory vesting = vestingOf[asset];
        uint256 totalAmount = vesting.totalAmount;
        if (totalAmount == 0) return 0;

        uint256 start = vesting.start;
        uint256 timestamp = block.timestamp;
        if (timestamp < start + vesting.cliffDuration) return 0;

        uint256 vestedAmount = timestamp >= start + vesting.vestingDuration
            ? totalAmount
            : totalAmount * (timestamp - start) / vesting.vestingDuration;

        return vestedAmount - vesting.claimedAmount;
    }

    /**
     * @notice Claims all currently vested assets for a position's recipient.
     * @dev If permissionless claims are disabled, only the recipient may call this function. Assets are always sent
     *      to the stored recipient.
     * @param asset Address of the vested asset.
     * @return amount Amount transferred to the recipient.
     */
    function claim(address asset) external returns (uint256 amount) {
        Vesting memory vesting = vestingOf[asset];
        if (vesting.totalAmount == 0) revert NoClaimableAmount();
        if (!vesting.permissionlessClaim && msg.sender != vesting.recipient) revert SenderNotRecipient();

        amount = claimable(asset);
        if (amount == 0) revert NoClaimableAmount();

        vestingOf[asset].claimedAmount += uint128(amount);
        SafeTransferLib.safeTransfer(asset, vesting.recipient, amount);
        emit VestingReleased(asset, vesting.recipient, uint128(amount));
    }

    /**
     * @notice Simulates creating a market and buying its asset without retaining any state changes.
     * @dev This function is not `view` because it executes the creation and swap before reverting them.
     *      It does not require numeraire funds or approval and should be called offchain with `eth_call`.
     * @param createData Creation data passed to Airlock.
     * @param exactAmountIn Exact amount of numeraire to simulate spending on the asset purchase.
     * @return asset Address of the asset that would be created.
     * @return poolKey Key identifying the created Uniswap V4 pool.
     * @return governance Address of the governance contract that would be created.
     * @return timelock Address of the timelock contract that would be created.
     * @return amountOut Amount of the created asset that the bundle would purchase after hook fees.
     */
    function simulateBundle(
        CreateParams calldata createData,
        uint128 exactAmountIn
    )
        external
        returns (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut)
    {
        if (exactAmountIn == 0) {
            revert ExactInputAmountZero();
        }

        try this._simulateBundle(createData, exactAmountIn) {
            revert UnexpectedSimulationSuccess();
        } catch (bytes memory reason) {
            return _parseBundleQuote(reason);
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SenderNotPoolManager();

        SwapCallbackData memory callbackData = abi.decode(data, (SwapCallbackData));
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: callbackData.zeroForOne,
            amountSpecified: -int256(uint256(callbackData.exactAmountIn)),
            sqrtPriceLimitX96: callbackData.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(callbackData.poolKey, params, bytes(""));
        int128 inputDelta = callbackData.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = callbackData.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 amountSpent = uint256(-int256(inputDelta));

        if (inputDelta >= 0 || outputDelta <= 0 || amountSpent != callbackData.exactAmountIn) {
            revert ExactInputNotFullySpent(callbackData.exactAmountIn, amountSpent);
        }
        uint128 amountOut = uint128(outputDelta);
        if (callbackData.simulate) revert SwapQuote(amountOut);

        Currency inputCurrency =
            callbackData.zeroForOne ? callbackData.poolKey.currency0 : callbackData.poolKey.currency1;
        Currency outputCurrency =
            callbackData.zeroForOne ? callbackData.poolKey.currency1 : callbackData.poolKey.currency0;

        poolManager.sync(inputCurrency);
        if (inputCurrency.isAddressZero()) {
            poolManager.settle{ value: amountSpent }();
        } else {
            SafeTransferLib.safeTransferFrom(
                Currency.unwrap(inputCurrency), callbackData.payer, address(poolManager), amountSpent
            );
            poolManager.settle();
        }

        poolManager.take(outputCurrency, callbackData.recipient, amountOut);
        return abi.encode(amountOut);
    }

    /// @dev Executes a complete simulation in a call frame that always reverts.
    function _simulateBundle(CreateParams calldata createData, uint128 exactAmountIn) external {
        if (msg.sender != address(this)) revert SenderNotSelf();

        BundleResult memory result = _createBundle(createData);
        try poolManager.unlock(
            abi.encode(
                SwapCallbackData({
                    poolKey: result.poolKey,
                    zeroForOne: result.zeroForOne,
                    exactAmountIn: exactAmountIn,
                    payer: address(0),
                    recipient: address(0),
                    simulate: true
                })
            )
        ) {
            revert UnexpectedSimulationSuccess();
        } catch (bytes memory reason) {
            uint128 quotedAmountOut = _parseSwapQuote(reason);
            revert BundleQuote(result.asset, result.poolKey, result.governance, result.timelock, quotedAmountOut);
        }
    }

    function _createBundle(CreateParams calldata createData) private returns (BundleResult memory result) {
        (result.asset,, result.governance, result.timelock,) = airlock.create(createData);

        (,,,,, result.poolKey,) =
            DopplerHookInitializer(payable(address(createData.poolInitializer))).getState(result.asset);

        address currency0 = Currency.unwrap(result.poolKey.currency0);
        address currency1 = Currency.unwrap(result.poolKey.currency1);

        if (currency0 == createData.numeraire && currency1 == result.asset) {
            result.zeroForOne = true;
        } else if (currency1 != createData.numeraire || currency0 != result.asset) {
            revert InvalidPool();
        }
    }

    function _parseSwapQuote(bytes memory reason) private pure returns (uint128 amountOut) {
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
        if (reason.length != 36 || selector != SwapQuote.selector) _revert(reason);

        assembly ("memory-safe") {
            amountOut := mload(add(reason, 0x24))
        }
    }

    function _parseBundleQuote(bytes memory reason)
        private
        pure
        returns (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut)
    {
        bytes4 selector;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
        if (reason.length != 292 || selector != BundleQuote.selector) _revert(reason);

        assembly ("memory-safe") {
            asset := mload(add(reason, 0x24))
            currency0 := mload(add(reason, 0x44))
            currency1 := mload(add(reason, 0x64))
            fee := mload(add(reason, 0x84))
            tickSpacing := mload(add(reason, 0xa4))
            hooks := mload(add(reason, 0xc4))
            governance := mload(add(reason, 0xe4))
            timelock := mload(add(reason, 0x104))
            amountOut := mload(add(reason, 0x124))
        }
        poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
    }

    function _revert(bytes memory reason) private pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
