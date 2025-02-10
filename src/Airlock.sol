// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";
import { SafeTransferLib, ERC20 } from "@solmate/utils/SafeTransferLib.sol";
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
 * @notice Data used to create a new asset token
 * @param initialSupply Total supply of the token (might be increased later on)
 * @param numTokensToSell Amount of tokens to sell in the Doppler hook
 * @param tokenFactory Address of the factory contract deploying the ERC20 token
 * @param tokenFactoryData Arbitrary data to pass to the token factory
 * @param governanceFactory Address of the factory contract deploying the governance
 * @param governanceFactoryData Arbitrary data to pass to the governance factory
 * @param liquidityMigrator Address of the liquidity migrator contract
 * @param integrator Address of the front-end integrator
 * @param salt Salt used by the different factories to deploy the contracts using CREATE2
 */
struct CreateParams {
    uint256 initialSupply;
    uint256 numTokensToSell;
    address numeraire;
    ITokenFactory tokenFactory;
    bytes tokenFactoryData;
    IGovernanceFactory governanceFactory;
    bytes governanceFactoryData;
    IPoolInitializer poolInitializer;
    bytes poolInitializerData;
    ILiquidityMigrator liquidityMigrator;
    bytes liquidityMigratorData;
    address integrator;
    bytes32 salt;
}

/**
 * @notice Emitted when a new asset token is created
 * @param asset Address of the asset token
 * @param numeraire Address of the numeraire token
 * @param initializer Address of the pool initializer contract, either based on uniswapV3 or uniswapV4
 * @param poolOrHook Address of the liquidity pool (if uniswapV3) or hook (if uniswapV4)
 */
event Create(address asset, address indexed numeraire, address initializer, address poolOrHook);

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

/**
 * @notice Emitted when fees are collected, either protocol or integrator
 * @param to Address receiving the fees
 * @param token Token from which the fees are collected
 * @param amount Amount of fees collected
 */
event Collect(address indexed to, address indexed token, uint256 amount);

/// @custom:security-contact security@whetstone.cc
contract Airlock is Ownable {
    using SafeTransferLib for ERC20;

    mapping(address module => ModuleState state) public getModuleState;
    mapping(address asset => AssetData data) public getAssetData;
    mapping(address token => uint256 amount) public getProtocolFees;
    mapping(address integrator => mapping(address token => uint256 amount)) public getIntegratorFees;

    receive() external payable { }

    /**
     * @param owner_ Address receiving the ownership of the Airlock contract
     */
    constructor(address owner_, address[] memory modules, ModuleState[] memory states) Ownable(owner_) {
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
     * @notice Deploys a new token with the associated governance, timelock and hook contracts
     */
    function create(
        CreateParams calldata createData
    ) external returns (address asset, address pool, address governance, address timelock, address migrationPool) {
        _validateModuleState(address(createData.tokenFactory), ModuleState.TokenFactory);
        _validateModuleState(address(createData.governanceFactory), ModuleState.GovernanceFactory);
        _validateModuleState(address(createData.poolInitializer), ModuleState.PoolInitializer);
        _validateModuleState(address(createData.liquidityMigrator), ModuleState.LiquidityMigrator);

        asset = createData.tokenFactory.create(
            createData.initialSupply, address(this), address(this), createData.salt, createData.tokenFactoryData
        );

        (governance, timelock) = createData.governanceFactory.create(asset, createData.governanceFactoryData);

        ERC20(asset).approve(address(createData.poolInitializer), createData.numTokensToSell);
        pool = createData.poolInitializer.initialize(
            asset, createData.numeraire, createData.numTokensToSell, createData.salt, createData.poolInitializerData
        );

        migrationPool =
            createData.liquidityMigrator.initialize(asset, createData.numeraire, createData.liquidityMigratorData);
        DERC20(asset).lockPool(migrationPool);

        uint256 excessAsset = ERC20(asset).balanceOf(address(this));

        if (excessAsset > 0) {
            ERC20(asset).safeTransfer(timelock, excessAsset);
        }

        getAssetData[asset] = AssetData({
            numeraire: createData.numeraire,
            timelock: timelock,
            governance: governance,
            liquidityMigrator: createData.liquidityMigrator,
            poolInitializer: createData.poolInitializer,
            pool: pool,
            migrationPool: migrationPool,
            numTokensToSell: createData.numTokensToSell,
            totalSupply: createData.initialSupply,
            integrator: createData.integrator == address(0) ? owner() : createData.integrator
        });

        emit Create(asset, createData.numeraire, address(createData.poolInitializer), pool);
    }

    /**
     * @notice Triggers the migration from the initial liquidity pool to the next one
     * @dev Since anyone can call this function, the conditions for the migration are checked by the
     * `poolInitializer` contract
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
        ) = assetData.poolInitializer.exitLiquidity(assetData.pool);

        _handleFees(token0, assetData.integrator, balance0, fees0);
        _handleFees(token1, assetData.integrator, balance1, fees1);

        address liquidityMigrator = address(assetData.liquidityMigrator);

        if (token0 == address(0)) {
            SafeTransferLib.safeTransferETH(liquidityMigrator, balance0 - fees0);
        } else {
            ERC20(token0).safeTransfer(liquidityMigrator, balance0 - fees0);
        }

        ERC20(token1).safeTransfer(liquidityMigrator, balance1 - fees1);

        assetData.liquidityMigrator.migrate(sqrtPriceX96, token0, token1, assetData.timelock);

        emit Migrate(asset, assetData.pool);
    }

    /**
     * @dev Computes and stores the protocol and integrators fees. Protocol fees are either 5% of the
     * trading fees or 0.1% of the proceeds (token balance excluding fees) capped at a maximum of 20%
     * of the trading fees
     * @param token Address of the token to handle fees from
     * @param integrator Address of the integrator to handle fees from
     * @param balance Balance of the token including fees
     * @param fees Trading fees
     */
    function _handleFees(address token, address integrator, uint256 balance, uint256 fees) internal {
        if (fees > 0) {
            uint256 protocolLpFees = fees / 20;
            uint256 protocolProceedsFees = (balance - fees) / 1000;
            uint256 protocolFees = Math.max(protocolLpFees, protocolProceedsFees);
            uint256 maxProtocolFees = fees / 5;
            uint256 integratorFees;

            (integratorFees, protocolFees) = protocolFees > maxProtocolFees
                ? (fees - maxProtocolFees, maxProtocolFees)
                : (fees - protocolFees, protocolFees);

            getProtocolFees[token] += protocolFees;
            getIntegratorFees[integrator][token] += integratorFees;
        }
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
        getProtocolFees[token] -= amount;

        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            ERC20(token).safeTransfer(to, amount);
        }

        emit Collect(to, token, amount);
    }

    /**
     * @notice Collects integrator fees
     * @param to Address receiving the fees
     * @param token Address of the token to collect fees from
     * @param amount Amount of fees to collect
     */
    function collectIntegratorFees(address to, address token, uint256 amount) external {
        getIntegratorFees[msg.sender][token] -= amount;

        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            ERC20(token).safeTransfer(to, amount);
        }

        emit Collect(to, token, amount);
    }

    /**
     * @dev Validates the state of a module
     * @param module Address of the module
     * @param state Expected state of the module
     */
    function _validateModuleState(address module, ModuleState state) internal view {
        require(getModuleState[address(module)] == state, WrongModuleState(module, state, getModuleState[module]));
    }
}
