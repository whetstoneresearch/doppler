// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IMorpho, MarketParams } from "@morpho-blue/interfaces/IMorpho.sol";
import { IMetaMorpho } from "@metamorpho/interfaces/IMetaMorpho.sol";
import { IMetaMorphoFactory } from "@metamorpho/interfaces/IMetaMorphoFactory.sol";

/// @notice Thrown when the sender is not the Airlock contract
error SenderNotAirlock();

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into a Morpho market and MetaMorpho vault
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

    /// @notice The MetaMorpho factory contract
    IMetaMorphoFactory public immutable metaMorphoFactory;

    /// @notice Mapping of asset pairs to their Morpho market params
    mapping(address asset => mapping(address numeraire => MarketParams)) public getMarketParams;

    /// @notice Mapping of asset pairs to their MetaMorpho vault
    mapping(address asset => mapping(address numeraire => address vault)) public getVault;

    constructor(
        address airlock_,
        address morpho_,
        address metaMorphoFactory_,
        address weth_
    ) {
        airlock = airlock_;
        morpho = IMorpho(morpho_);
        metaMorphoFactory = IMetaMorphoFactory(metaMorphoFactory_);
        weth = IWETH(payable(weth_));
    }

    function initialize(address asset, address numeraire, bytes calldata data) external returns (address) {
        require(msg.sender == airlock, SenderNotAirlock());

        // Handle ETH case
        if (asset == address(0)) asset = address(weth);
        if (numeraire == address(0)) numeraire = address(weth);

        // Decode initialization parameters
        (
            uint256 ltv,
            address oracle,
            address irm,
            address initialOwner,
            uint256 initialTimelock,
            string memory name,
            string memory symbol,
            bytes32 salt
        ) = abi.decode(data, (uint256, address, address, address, uint256, string, string, bytes32));

        // Create market params for Morpho market with numeraire as lend asset and asset as collateral
        MarketParams memory params = MarketParams({
            loanToken: numeraire,
            collateralToken: asset,
            oracle: oracle,
            irm: irm,
            lltv: ltv
        });

        getMarketParams[asset][numeraire] = params;

        // Create MetaMorpho vault with initialOwner and timelock
        address vault = address(metaMorphoFactory.createMetaMorpho(
            initialOwner,
            initialTimelock,
            numeraire,
            name,
            symbol,
            salt
        ));
        getVault[asset][numeraire] = vault;

        return vault;
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
        }
        if (token1 == address(0)) {
            token1 = address(weth);
        }

        // Check both orderings to determine which token is the asset
        MarketParams memory params;
        address vault;
        address asset;
        address numeraire;

        vault = getVault[token0][token1];
        if (vault != address(0)) {
            params = getMarketParams[token0][token1];
            asset = token0;
            numeraire = token1;
        } else {
            vault = getVault[token1][token0];
            params = getMarketParams[token1][token0];
            asset = token1;
            numeraire = token0;
        }
        require(params.loanToken != address(0) && vault != address(0), "Market not initialized");

        // Supply numeraire tokens to vault
        uint256 balance = ERC20(numeraire).balanceOf(address(this));
        if (balance > 0) {
            ERC20(numeraire).safeApprove(vault, balance);
            IMetaMorpho(vault).deposit(balance, recipient);
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
