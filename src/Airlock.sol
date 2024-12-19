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

/// @notice Thrown when the module state is not the expected one
error WrongModuleState(address module, ModuleState expected, ModuleState actual);

/// @notice Thrown when the lengths of two arrays do not match
error ArrayLengthsMismatch();

/**
 * @notice Data related to the asset token
 * @param numeraire Address of the numeraire token
 * @param timelock Address of the timelock contract
 * @param governance Address of the governance contract
 * @param liquidityMigrator Address of the liquidity migrator contract
 * @param poolInitializer Address of the pool initializer contract
 * @param pool Address of the liquidity pool
 * @param migrationPool Address of the liquidity pool after migration
 * @param numTokensToSell Amount of tokens to sell
 * @param totalSupply Total supply of the token
 * @param integrator Address of the front-end integrator
 * @param targetTick Target tick at which migration actions is available
 */
struct AssetData {
    address numeraire;
    address timelock;
    address governance;
    ILiquidityMigrator liquidityMigrator;
    IPoolInitializer poolInitializer;
    address pool;
    address migrationPool;
    uint256 numTokensToSell;
    uint256 totalSupply;
    address integrator;
}

/**
 * @notice Emitted when a new asset token is created
 * @param asset Address of the asset token
 * @param numeraire Address of the numeraire token
 */
event Create(address asset, address indexed numeraire);

/**
 * @notice Emitted when an asset token is migrated
 * @param asset Address of the asset token
 * @param pool Address of the liquidity pool
 */
event Migrate(address indexed asset, address indexed pool);

/**
 * @notice Emitted when the state of a module is set
 * @param module Address of the module
 * @param state State of the module
 */
event SetModuleState(address indexed module, ModuleState indexed state);

event Collect(address indexed to, address indexed token, uint256 amount);

/// @custom:security-contact security@whetstone.cc
contract Airlock is Ownable {
    mapping(address module => ModuleState state) public getModuleState;
    mapping(address asset => AssetData data) public getAssetData;
    mapping(address token => uint256 amount) public protocolFees;
    mapping(address integrator => mapping(address token => uint256 amount)) public integratorFees;

    receive() external payable {
        // TODO: We might want to restrict this to only approved poolInitializer contracts
    }

    /**
     * @param owner_ Address receiving the ownership of the Airlock contract
     */
    constructor(
        address owner_
    ) Ownable(owner_) { }

    /**
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
        address integrator,
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
            migrationPool: migrationPool,
            numTokensToSell: numTokensToSell,
            totalSupply: initialSupply,
            integrator: integrator
        });

        emit Create(asset, numeraire);
    }

    /**
     * @notice Triggers the migration from one liquidity pool to another
     * @param asset Address of the token to migrate
     */
    function migrate(
        address asset
    ) external {
        AssetData memory assetData = getAssetData[asset];

        DERC20(asset).unlockPool();
        Ownable(asset).transferOwnership(assetData.timelock);

        (
            uint160 sqrtPriceX96,
            address token0,
            uint128 fees0,
            uint128 balance0,
            address token1,
            uint128 fees1,
            uint128 balance1
        ) = assetData.poolInitializer.exitLiquidity(asset);

        uint256 protocolLpFees0 = fees0 * 5 / 100;
        uint256 protocolLpFees1 = fees1 * 5 / 100;

        uint256 protocolProceedsFees0 = (balance0 - fees0) / 1000;
        uint256 protocolProceedsFees1 = (balance1 - fees1) / 1000;

        uint256 protocolFees0 = protocolLpFees0 > protocolProceedsFees0 ? protocolLpFees0 : protocolProceedsFees0;
        uint256 protocolFees1 = protocolLpFees1 > protocolProceedsFees1 ? protocolLpFees1 : protocolProceedsFees1;

        uint256 integratorFees0 = fees0 - protocolFees0;
        uint256 integratorFees1 = fees1 - protocolFees1;

        protocolFees[token0] += protocolFees0;
        protocolFees[token1] += protocolFees1;
        integratorFees[assetData.integrator][token0] += integratorFees0;
        integratorFees[assetData.integrator][token1] += integratorFees1;

        uint256 total0 = balance0 - fees0;
        uint256 total1 = balance1 - fees1;

        if (token0 == asset) {
            total0 += assetData.totalSupply - assetData.numTokensToSell;
        } else {
            total1 += assetData.totalSupply - assetData.numTokensToSell;
        }

        ERC20(token0).transfer(address(assetData.liquidityMigrator), total0);
        ERC20(token1).transfer(address(assetData.liquidityMigrator), total1);

        assetData.liquidityMigrator.migrate(sqrtPriceX96, token0, token1, assetData.timelock);

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

    /**
     * @notice Collects protocol fees
     * @param to Address receiving the fees
     * @param token Address of the token to collect fees from
     * @param amount Amount of fees to collect
     */
    function collectProtocolFees(address to, address token, uint256 amount) external onlyOwner {
        protocolFees[token] -= amount;
        ERC20(token).transfer(to, amount);
        emit Collect(to, token, amount);
    }

    /**
     * @notice Collects integrator fees
     * @param to Address receiving the fees
     * @param token Address of the token to collect fees from
     * @param amount Amount of fees to collect
     */
    function collectIntegratorFees(address to, address token, uint256 amount) external {
        integratorFees[msg.sender][token] -= amount;
        ERC20(token).transfer(to, amount);
        emit Collect(to, token, amount);
    }
}
