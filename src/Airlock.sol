// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

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

error WrongModuleState();

error WrongInitialSupply();

error ArrayLengthsMismatch();

struct AssetData {
    address numeraire;
    address timelock;
    address governance;
    ILiquidityMigrator liquidityMigrator;
    IPoolInitializer poolInitializer;
    address[] recipients;
    uint256[] amounts;
    address pool;
    address migrationPool;
}

event Create(address asset, address indexed numeraire);

event Migrate(address asset, address pool);

event SetModuleState(address module, ModuleState state);

contract Airlock is Ownable {
    mapping(address module => ModuleState state) public getModuleState;
    mapping(address asset => AssetData data) public getAssetData;

    receive() external payable { }

    constructor(
        address owner_
    ) Ownable(owner_) { }

    /**
     * TODO:
     * - Creating a token should incur fees (platform and frontend fees)
     *
     * @notice Deploys a new token with the associated governance, timelock and hook contracts
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param initialSupply Total supply of the token (might be increased later on)
     * @param numTokensToSell Amount of tokens to sell in the Doppler hook
     * @param recipients Array of addresses to receive tokens after the migration
     * @param amounts Array of amounts to receive after the migration
     * @param tokenFactory Address of the factory contract deploying the ERC20 token
     * @param tokenData Arbitrary data to pass to the token factory
     * @param governanceFactory Address of the factory contract deploying the governance
     * @param governanceData Arbitrary data to pass to the governance factory
     * @param liquidityMigrator Address of the liquidity migrator contract
     */
    function create(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 numTokensToSell,
        address numeraire,
        address[] memory recipients,
        uint256[] memory amounts,
        ITokenFactory tokenFactory,
        bytes memory tokenData,
        IGovernanceFactory governanceFactory,
        bytes memory governanceData,
        IPoolInitializer poolInitializer,
        bytes memory poolInitializerData,
        ILiquidityMigrator liquidityMigrator,
        bytes memory liquidityMigratorData
    ) external returns (address asset, address pool, address governance, address timelock, address migrationPool) {
        require(getModuleState[address(tokenFactory)] == ModuleState.TokenFactory, WrongModuleState());
        require(getModuleState[address(governanceFactory)] == ModuleState.GovernanceFactory, WrongModuleState());
        require(getModuleState[address(poolInitializer)] == ModuleState.PoolInitializer, WrongModuleState());
        require(getModuleState[address(liquidityMigrator)] == ModuleState.LiquidityMigrator, WrongModuleState());

        require(recipients.length == amounts.length, ArrayLengthsMismatch());

        bytes32 salt = keccak256(
            abi.encodePacked(
                name,
                symbol,
                initialSupply,
                numTokensToSell,
                numeraire,
                recipients,
                amounts,
                tokenFactory,
                tokenData,
                governanceFactory,
                governanceData,
                poolInitializer,
                poolInitializerData,
                liquidityMigrator,
                liquidityMigratorData
            )
        );

        uint256 totalToMint = numTokensToSell;
        for (uint256 i; i < amounts.length; i++) {
            totalToMint += amounts[i];
        }
        require(totalToMint == initialSupply, WrongInitialSupply());

        asset = tokenFactory.create(name, symbol, initialSupply, address(this), address(this), pool, tokenData, salt);

        (governance, timelock) = governanceFactory.create(name, asset, governanceData);

        ERC20(asset).approve(address(poolInitializer), numTokensToSell);
        pool = poolInitializer.initialize(asset, numTokensToSell, salt, poolInitializerData);

        migrationPool = liquidityMigrator.initialize(liquidityMigratorData);

        getAssetData[asset] = AssetData({
            numeraire: numeraire,
            timelock: timelock,
            governance: governance,
            liquidityMigrator: liquidityMigrator,
            poolInitializer: poolInitializer,
            recipients: recipients,
            amounts: amounts,
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

        uint256 length = assetData.recipients.length;
        for (uint256 i; i < length; i++) {
            ERC20(asset).transfer(assetData.recipients[i], assetData.amounts[i]);
        }

        DERC20(asset).unlockPool();
        Ownable(asset).transferOwnership(assetData.timelock);
        (uint256 price) = IPoolInitializer(assetData.poolInitializer).exitLiquidity(asset);
        (address pool,) = assetData.migrator.migrate(price, assetData.timelock, new bytes(0));

        emit Migrate(asset, pool);
    }

    /**
     * @notice Sets the state of the givens modules
     * @param modules Array of module addresses
     * @param states Array of module states
     */
    function setModuleState(address[] memory modules, ModuleState[] memory states) external onlyOwner {
        uint256 length = modules.length;

        if (length != states.length) {
            revert ArrayLengthsMismatch();
        }

        for (uint256 i; i < length; i++) {
            getModuleState[modules[i]] = states[i];
            emit SetModuleState(modules[i], states[i]);
        }
    }
}
