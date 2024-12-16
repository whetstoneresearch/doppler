// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { DERC20 } from "src/DERC20.sol";

enum ModuleState {
    NotWhitelisted,
    TokenFactory,
    GovernanceFactory,
    PoolInitializer,
    LiquidityMigrator
}

error WrongModuleState(address module, ModuleState expected, ModuleState actual);

error WrongInitialSupply();

error ArrayLengthsMismatch();

struct AssetData {
    address numeraire;
    address timelock;
    address governance;
    ILiquidityMigrator liquidityMigrator;
    IPoolInitializer poolInitializer;
    address pool;
    address migrationPool;
}

event Create(address asset, address indexed numeraire);

event Migrate(address indexed asset, address indexed pool);

event SetModuleState(address indexed module, ModuleState indexed state);

/// @custom:security-contact security@whetstone.cc
contract Airlock is Ownable {
    mapping(address module => ModuleState state) public getModuleState;
    mapping(address asset => AssetData data) public getAssetData;

    receive() external payable {
        // TODO: We might want to restrict this to only approved poolInitializer contracts
    }

    constructor(
        address owner_
    ) Ownable(owner_) { }

    /**
     * TODO:
     * - Creating a token should incur fees (platform and frontend fees)
     *
     * @notice Deploys a new token with the associated governance, timelock and hook contracts
     * @param initialSupply Total supply of the token (might be increased later on)
     * @param numTokensToSell Amount of tokens to sell in the Doppler hook
     * @param tokenFactory Address of the factory contract deploying the ERC20 token
     * @param tokenFactoryData Arbitrary data to pass to the token factory
     * @param governanceFactory Address of the factory contract deploying the governance
     * @param governanceFactoryData Arbitrary data to pass to the governance factory
     * @param liquidityMigrator Address of the liquidity migrator contract
     */
    function create(
        uint256 initialSupply,
        uint256 numTokensToSell,
        address numeraire,
        ITokenFactory tokenFactory,
        bytes calldata tokenFactoryData,
        IGovernanceFactory governanceFactory,
        bytes calldata governanceFactoryData,
        IPoolInitializer poolInitializer,
        bytes calldata poolInitializerData,
        ILiquidityMigrator liquidityMigrator,
        bytes calldata liquidityMigratorData,
        bytes32 salt
    ) external returns (address asset, address pool, address governance, address timelock, address migrationPool) {
        require(
            getModuleState[address(tokenFactory)] == ModuleState.TokenFactory,
            WrongModuleState(address(tokenFactory), ModuleState.TokenFactory, getModuleState[address(tokenFactory)])
        );
        require(
            getModuleState[address(governanceFactory)] == ModuleState.GovernanceFactory,
            WrongModuleState(
                address(governanceFactory), ModuleState.GovernanceFactory, getModuleState[address(governanceFactory)]
            )
        );
        require(
            getModuleState[address(poolInitializer)] == ModuleState.PoolInitializer,
            WrongModuleState(
                address(poolInitializer), ModuleState.PoolInitializer, getModuleState[address(poolInitializer)]
            )
        );
        require(
            getModuleState[address(liquidityMigrator)] == ModuleState.LiquidityMigrator,
            WrongModuleState(
                address(liquidityMigrator), ModuleState.LiquidityMigrator, getModuleState[address(liquidityMigrator)]
            )
        );

        /*
        bytes32 salt = keccak256(
            abi.encodePacked(
                initialSupply,
                numTokensToSell,
                numeraire,
                recipients,
                amounts,
                tokenFactory,
                tokenFactoryData,
                governanceFactory,
                governanceFactoryData,
                poolInitializer,
                poolInitializerData,
                liquidityMigrator,
                liquidityMigratorData
            )
        );
        */

        /*
        uint256 totalToMint = numTokensToSell;
        for (uint256 i; i < amounts.length; ++i) {
            totalToMint += amounts[i];
        }
        require(totalToMint == initialSupply, WrongInitialSupply());
        */

        asset = tokenFactory.create(initialSupply, address(this), address(this), salt, tokenFactoryData);

        (governance, timelock) = governanceFactory.create(asset, governanceFactoryData);

        ERC20(asset).approve(address(poolInitializer), numTokensToSell);
        poolInitializer.initialize(asset, numeraire, numTokensToSell, salt, poolInitializerData);

        migrationPool = liquidityMigrator.initialize(asset, numeraire, liquidityMigratorData);

        getAssetData[asset] = AssetData({
            numeraire: numeraire,
            timelock: timelock,
            governance: governance,
            liquidityMigrator: liquidityMigrator,
            poolInitializer: poolInitializer,
            pool: pool,
            migrationPool: migrationPool
        });

        emit Create(asset, numeraire);
    }

    /**
     * @notice Triggers the migration from the Doppler hook to another liquidity pool
     * @param asset Address of the token to migrate
     */
    function migrate(
        address asset
    ) external {
        AssetData memory assetData = getAssetData[asset];

        DERC20(asset).unlockPool();
        Ownable(asset).transferOwnership(assetData.timelock);
        (uint160 sqrtPriceX96, address token0, uint256 amount0, address token1, uint256 amount1) =
            assetData.poolInitializer.exitLiquidity(asset);
        assetData.liquidityMigrator.migrate{ value: address(this).balance > 0 ? address(this).balance : 0 }(
            sqrtPriceX96, token0, amount0, token1, amount1, assetData.timelock, new bytes(0)
        );

        emit Migrate(asset, assetData.pool);
    }

    /**
     * @notice Sets the state of the givens modules
     * @param modules Array of module addresses
     * @param states Array of module states
     */
    function setModuleState(address[] calldata modules, ModuleState[] calldata states) external onlyOwner {
        uint256 length = modules.length;

        if (length != states.length) {
            revert ArrayLengthsMismatch();
        }

        for (uint256 i; i < length; ++i) {
            getModuleState[modules[i]] = states[i];
            emit SetModuleState(modules[i], states[i]);
        }
    }
}
