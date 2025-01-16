// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IMorpho } from "@morpho-blue/interfaces/IMorpho.sol";
import { IMorphoVault } from "src/interfaces/IMorphoVault.sol";

/// @notice Thrown when the sender is not the Airlock contract
error SenderNotAirlock();

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Morpho market and vault
 * @custom:security-contact security@whetstone.cc
 */
contract MorphoMigrator is ILiquidityMigrator {
    using SafeTransferLib for ERC20;
    using FullMath for uint256;
    using FullMath for uint160;

    /// @notice The Airlock contract that controls this migrator
    address public immutable airlock;

    /// @notice The WETH contract for handling ETH wrapping
    IWETH public immutable weth;

    /// @notice The Morpho protocol contract
    IMorpho public immutable morpho;

    /// @notice The Morpho vault factory contract
    IMorphoVaultFactory public immutable vaultFactory;

    /// @notice Mapping of asset pairs to their Morpho market ID
    mapping(address asset => mapping(address numeraire => uint256 marketId)) public getMarketId;

    /// @notice Mapping of asset pairs to their Morpho vault
    mapping(address asset => mapping(address numeraire => address vault)) public getVault;

    constructor(
        address airlock_,
        address morpho_,
        address vaultFactory_,
        address weth_
    ) {
        airlock = airlock_;
        morpho = IMorpho(morpho_);
        vaultFactory = IMorphoVaultFactory(vaultFactory_);
        weth = IWETH(payable(weth_));
    }

    function initialize(address asset, address numeraire, bytes calldata data) external returns (address) {
        require(msg.sender == airlock, SenderNotAirlock());

        // Handle ETH case
        if (asset == address(0)) asset = address(weth);
        if (numeraire == address(0)) numeraire = address(weth);

        // Decode initialization parameters
        (uint256 ltv, address oracle, address timelock) = abi.decode(data, (uint256, address, address));

        // Create Morpho market with numeraire as lend asset and asset as collateral
        uint256 marketId = morpho.createMarket(
            numeraire,
            asset,
            ltv,
            oracle
        );
        getMarketId[asset][numeraire] = marketId;

        // Create Morpho vault owned by timelock
        address vault = vaultFactory.createVault(
            marketId,
            timelock
        );
        getVault[asset][numeraire] = vault;

        return address(vault);
    }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable returns (uint256 liquidity) {
        require(msg.sender == airlock, SenderNotAirlock());

        // Handle ETH case
        if (token0 == address(0)) {
            token0 = address(weth);
            weth.deposit{ value: address(this).balance }();
        }
        if (token1 == address(0)) {
            token1 = address(weth);
            weth.deposit{ value: address(this).balance }();
        }

        // Get market and vault
        uint256 marketId = getMarketId[token0][token1];
        address vault = getVault[token0][token1];
        require(marketId != 0 && vault != address(0), "Market not initialized");

        // Supply numeraire tokens to vault
        uint256 balance = ERC20(token1).balanceOf(address(this));
        if (balance > 0) {
            ERC20(token1).safeApprove(vault, balance);
            IMorphoVault(vault).deposit(balance, recipient);
            liquidity = balance;
        }

        // Transfer any remaining dust to recipient
        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(recipient, address(this).balance);
        }

        uint256 dust0 = ERC20(token0).balanceOf(address(this));
        if (dust0 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token0), recipient, dust0);
        }

        uint256 dust1 = ERC20(token1).balanceOf(address(this));
        if (dust1 > 0) {
            SafeTransferLib.safeTransfer(ERC20(token1), recipient, dust1);
        }
    }
}

