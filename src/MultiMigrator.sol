// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
import { WETH as IWETH } from "@solmate/tokens/WETH.sol";
import { FixedPoint96 } from "@v4-core/libraries/FixedPoint96.sol";
import { FullMath } from "@v4-core/libraries/FullMath.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { Airlock } from "src/Airlock.sol";

/// @notice Thrown when the sender is not the Airlock contract
error SenderNotAirlock();

/**
 * @author Whetstone Research
 * @notice Takes care of migrating liquidity into multiple modules proportionally
 * @custom:security-contact security@whetstone.cc
 */
contract MultiMigrator is ILiquidityMigrator {
    using SafeTransferLib for ERC20;
    using FullMath for uint256;
    using FullMath for uint160;

    /// @notice The Airlock contract that controls this migrator
    address public immutable airlock;

    /// @notice The WETH contract for handling ETH wrapping
    IWETH public immutable weth = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    /// @notice List of migrators that will receive tokens proportionally
    ILiquidityMigrator[] public migrators;

    /// @notice Percentage of asset tokens each migrator should receive (in basis points)
    uint256[] public assetPercentages;

    /// @notice Percentage of numeraire tokens each migrator should receive (in basis points) 
    uint256[] public numerairePercentages;

    /// @notice Total number of basis points allocated (should sum to 10000)
    uint256 public constant TOTAL_BASIS_POINTS = 10000;

    constructor(address airlock_) {
        airlock = airlock_;
    }

    function initialize(address asset, address numeraire, bytes calldata data) external returns (address) {
        require(msg.sender == airlock, SenderNotAirlock());

        // Handle ETH case by replacing with WETH
        if (asset == address(0)) asset = address(weth);
        if (numeraire == address(0)) numeraire = address(weth);

        // Decode the array of calldata
        bytes[] memory allData = abi.decode(data, (bytes[]));
        require(allData.length > 0, "Empty calldata");

        // Decode first item containing migrators and percentages
        (
            ILiquidityMigrator[] memory _migrators,
            uint256[] memory _assetPercentages,
            uint256[] memory _numerairePercentages
        ) = abi.decode(allData[0], (ILiquidityMigrator[], uint256[], uint256[]));
        
        require(_migrators.length == _assetPercentages.length, "Asset length mismatch");
        require(_migrators.length == _numerairePercentages.length, "Numeraire length mismatch");
        require(allData.length == _migrators.length + 1, "Invalid calldata length");
        
        uint256 totalAssetPercentage;
        uint256 totalNumerairePercentage;
        for (uint256 i = 0; i < _migrators.length; i++) {
            require(_assetPercentages[i] > 0 || _numerairePercentages[i] > 0, "Zero percentages");
            totalAssetPercentage += _assetPercentages[i];
            totalNumerairePercentage += _numerairePercentages[i];
        }
        require(totalAssetPercentage == TOTAL_BASIS_POINTS, "Asset percentages must sum to 10000");
        require(totalNumerairePercentage == TOTAL_BASIS_POINTS, "Numeraire percentages must sum to 10000");

        // Store migrators and their percentages
        migrators = _migrators;
        assetPercentages = _assetPercentages;
        numerairePercentages = _numerairePercentages;

        // Initialize each migrator with its specific calldata
        address lastPool;
        for (uint256 i = 0; i < migrators.length; i++) {
            lastPool = migrators[i].initialize(asset, numeraire, allData[i + 1]);
        }

        return lastPool;
    }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address recipient
    ) external payable returns (uint256 totalLiquidity) {
        require(msg.sender == airlock, SenderNotAirlock());

        // Convert ETH to WETH if needed
        if (token0 == address(0)) {
            token0 = address(weth);
            weth.deposit{ value: address(this).balance }();
        }
        if (token1 == address(0)) {
            token1 = address(weth);
            weth.deposit{ value: address(this).balance }();
        }

        uint256 initialBalance0 = ERC20(token0).balanceOf(address(this));
        uint256 initialBalance1 = ERC20(token1).balanceOf(address(this));

        // Migrate proportionally to each migrator
        for (uint256 i = 0; i < migrators.length; i++) {
            uint256 amount0 = (initialBalance0 * assetPercentages[i]) / TOTAL_BASIS_POINTS;
            uint256 amount1 = (initialBalance1 * numerairePercentages[i]) / TOTAL_BASIS_POINTS;
            if (amount0 > 0) {
                ERC20(token0).safeTransfer(address(migrators[i]), amount0);
            }
            if (amount1 > 0) {
                ERC20(token1).safeTransfer(address(migrators[i]), amount1); 
            }
            
            totalLiquidity += migrators[i].migrate(
                sqrtPriceX96,
                token0,
                token1,
                recipient
            );
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
