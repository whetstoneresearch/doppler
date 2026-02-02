// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { IV4Quoter } from "@v4-periphery/interfaces/IV4Quoter.sol";
import { Airlock, CreateParams } from "src/Airlock.sol";
import { IBundleCallback, CreateResult, Transfer, Call } from "src/interfaces/IBundleCallback.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { UniswapV4MulticurveInitializer } from "src/initializers/UniswapV4MulticurveInitializer.sol";

/// @dev Thrown when an invalid address is passed as a contructor parameter
error InvalidAddresses();

/// @dev Thrown when the asset address doesn't match the predicted one
error InvalidOutputToken();

/// @dev Thrown when the amount to quote exceeds the uint128 limit
error ExactAmountTooLarge();

/// @dev Thrown when the asset is not part of the resulting pool
error AssetNotInPool();

/// @dev Thrown when the provided exact amount is zero
error ExactAmountZero();

/// @dev Thrown when a planned call fails
error CallFailed();

/**
 * @author Whetstone
 * @custom:security-contact security@whetstone.cc
 */
contract Bundler {
    /// @notice Address of the Airlock contract
    Airlock public immutable airlock;

    /// @notice Address of the Universal Router contract
    UniversalRouter public immutable router;

    /// @notice Address of the QuoterV2 contract
    IQuoterV2 public immutable quoter;

    /// @notice Address of the Uniswap V4 Quoter contract
    IV4Quoter public immutable v4Quoter;

    /**
     * @param airlock_ Immutable address of the Airlock contract
     * @param router_ Immutable address of the Universal Router contract
     * @param quoter_ Immutable address of the QuoterV2 contract
     */
    constructor(Airlock airlock_, UniversalRouter router_, IQuoterV2 quoter_, IV4Quoter v4Quoter_) {
        if (
            address(airlock_) == address(0) || address(router_) == address(0) || address(quoter_) == address(0)
                || address(v4Quoter_) == address(0)
        ) {
            revert InvalidAddresses();
        }

        airlock = Airlock(airlock_);
        router = UniversalRouter(router_);
        quoter = IQuoterV2(quoter_);
        v4Quoter = IV4Quoter(v4Quoter_);
    }

    /**
     * @notice Simulates a bundle operation with an exact output amount
     * @param createData Creation data to pass to the Airlock contract
     * @param params Exact output parameters to pass to the QuoterV2 contract
     * @return amountIn Amount of input token required to receive the exact output amount
     */
    function simulateBundleExactOut(
        CreateParams calldata createData,
        IQuoterV2.QuoteExactOutputSingleParams calldata params
    ) external returns (uint256 amountIn) {
        (address asset,,,,) = airlock.create(createData);
        if (asset != params.tokenOut) {
            revert InvalidOutputToken();
        }
        (amountIn,,,) = quoter.quoteExactOutputSingle(params);
    }

    /**
     * @notice Simulates a bundle operation with an exact input amount
     * @param createData Creation data to pass to the Airlock contract
     * @param params Exact input parameters to pass to the QuoterV2 contract
     * @return amountOut Amount of output token received from the exact input amount
     */
    function simulateBundleExactIn(
        CreateParams calldata createData,
        IQuoterV2.QuoteExactInputSingleParams calldata params
    ) external returns (uint256 amountOut) {
        (address asset,,,,) = airlock.create(createData);
        if (asset != params.tokenOut) {
            revert InvalidOutputToken();
        }
        (amountOut,,,) = quoter.quoteExactInputSingle(params);
    }

    /**
     * @notice Simulates a multicurve bundle, returning the pool key and the quote to purchase the issued tokens
     * @param createData Creation data to pass to the Airlock contract
     * @return asset Address of the created asset token
     * @return poolKey PoolKey associated with the initialized Uniswap V4 pool
     * @return amountIn Numeraire required to receive the requested asset amount
     * @return gasEstimate Estimated gas for the swap quote
     */
    function simulateMulticurveBundleExactOut(
        CreateParams calldata createData,
        uint128 exactAmountOut,
        bytes calldata hookData
    )
        external
        returns (address asset, PoolKey memory poolKey, uint256 amountIn, uint256 gasEstimate)
    {
        bool zeroForOne;
        (asset, poolKey, zeroForOne) = _prepareMulticurveQuote(createData);

        uint128 amount = _resolveExactOutAmount(createData, exactAmountOut);

        (amountIn, gasEstimate) = v4Quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                exactAmount: amount,
                hookData: hookData
            })
        );
    }

    function simulateMulticurveBundleExactIn(
        CreateParams calldata createData,
        uint128 exactAmountIn,
        bytes calldata hookData
    )
        external
        returns (address asset, PoolKey memory poolKey, uint256 amountOut, uint256 gasEstimate)
    {
        if (exactAmountIn == 0) revert ExactAmountZero();

        bool zeroForOne;
        (asset, poolKey, zeroForOne) = _prepareMulticurveQuote(createData);

        (amountOut, gasEstimate) = v4Quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                exactAmount: exactAmountIn,
                hookData: hookData
            })
        );
    }

    function _prepareMulticurveQuote(CreateParams calldata createData)
        private
        returns (address asset, PoolKey memory poolKey, bool zeroForOne)
    {
        (asset,,,,) = airlock.create(createData);
        (, , poolKey,) = UniswapV4MulticurveInitializer(payable(address(createData.poolInitializer))).getState(asset);

        address currency0 = Currency.unwrap(poolKey.currency0);
        address currency1 = Currency.unwrap(poolKey.currency1);

        if (asset == currency0) {
            zeroForOne = false;
        } else if (asset == currency1) {
            zeroForOne = true;
        } else {
            revert AssetNotInPool();
        }
    }

    function _resolveExactOutAmount(CreateParams calldata createData, uint128 overrideAmount)
        private
        pure
        returns (uint128 amount)
    {
        if (overrideAmount != 0) {
            amount = overrideAmount;
        } else {
            uint256 numTokensToSell = createData.numTokensToSell;
            if (numTokensToSell == 0) revert ExactAmountZero();
            if (numTokensToSell > type(uint128).max) revert ExactAmountTooLarge();
            amount = uint128(numTokensToSell);
        }
    }

    /**
     * @notice Bundles the creation of an asset via the Airlock contract and a buy operation via the Universal Router
     * @param createData Creation data to pass to the Airlock contract
     * @param commands Encoded commands for the Universal Router
     * @param inputs Encoded inputs for the Universal Router
     */
    function bundle(
        CreateParams calldata createData,
        bytes calldata commands,
        bytes[] calldata inputs
    ) external payable {
        (address asset,,,,) = airlock.create(createData);
        uint256 balance = address(this).balance;
        router.execute{ value: balance }(commands, inputs);

        _sweep(asset, createData.numeraire, msg.sender);
    }

    /**
     * @notice Bundle with callback for complex flows (e.g., prebuy to vault)
     * @param createData Creation parameters
     * @param commands Router commands
     * @param inputs Router inputs
     * @param callback Contract to plan post-execution actions
     * @param callbackData Data for callback planning
     */
    function bundleWithPlan(
        CreateParams calldata createData,
        bytes calldata commands,
        bytes[] calldata inputs,
        IBundleCallback callback,
        bytes calldata callbackData
    ) external payable {
        (address asset, address pool, address governance, address timelock, address migrationPool) = airlock.create(
            createData
        );
        
        // Execute router (tokens end up in bundler)
        router.execute{ value: address(this).balance }(commands, inputs);

        // Get callback plan
        CreateResult memory result = CreateResult({
            asset: asset,
            pool: pool,
            governance: governance,
            timelock: timelock,
            migrationPool: migrationPool
        });
        
        (Transfer[] memory transfers, Call[] memory calls) = callback.plan(result, callbackData);

        // Execute transfers (e.g., send tokens to vault)
        for (uint256 i = 0; i < transfers.length; i++) {
            Transfer memory transfer = transfers[i];
            if (transfer.amount > 0) {
                SafeTransferLib.safeTransfer(transfer.token, transfer.to, transfer.amount);
            }
        }

        // Execute calls (e.g., vault records deposit)
        for (uint256 i = 0; i < calls.length; i++) {
            Call memory plannedCall = calls[i];
            (bool success,) = plannedCall.target.call{ value: plannedCall.value }(plannedCall.data);
            if (!success) revert CallFailed();
        }

        // Sweep remaining tokens to caller
        _sweep(asset, createData.numeraire, msg.sender);
    }

    /**
     * @notice Sweep all token balances to recipient
     * @param asset Asset token to sweep
     * @param numeraire Numeraire token to sweep
     * @param recipient Address to receive swept tokens
     */
    function _sweep(address asset, address numeraire, address recipient) internal {
        // Sweep ETH
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) SafeTransferLib.safeTransferETH(recipient, ethBalance);

        // Sweep asset
        uint256 assetBalance = SafeTransferLib.balanceOf(asset, address(this));
        if (assetBalance > 0) SafeTransferLib.safeTransfer(asset, recipient, assetBalance);

        // Sweep numeraire
        uint256 numeraireBalance = SafeTransferLib.balanceOf(numeraire, address(this));
        if (numeraireBalance > 0) SafeTransferLib.safeTransfer(numeraire, recipient, numeraireBalance);
    }
}
