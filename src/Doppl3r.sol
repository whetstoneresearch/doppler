// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import { LiquidityAmounts } from "@v3-periphery/libraries/LiquidityAmounts.sol";
import { TickMath } from "@v3-core/libraries/TickMath.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

import { DERC20 } from "src/DERC20.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IMigrator } from "src/interfaces/IMigrator.sol";

enum ModuleState {
    NotWhitelisted,
    TokenFactory,
    GovernanceFactory,
    Migrator
}

error WrongModuleState();

error WrongInitialSupply();

error ArrayLengthsMismatch();

error UnexpectedETH();

struct TokenData {
    address numeraire;
    address timelock;
    address governance;
    IMigrator migrator;
    address[] recipients;
    uint256[] amounts;
    address pool;
    address migratedPool;
}

event Create(address asset, address indexed numeraire, address pool);

event Migrate(address asset, address pool);

event SetModuleState(address module, ModuleState state);

contract Doppl3r is Ownable, IUniswapV3MintCallback {
    IUniswapV3Factory public immutable factory;

    mapping(address => ModuleState) public getModuleState;
    mapping(address token => TokenData) public getTokenData;

    receive() external payable {
        revert UnexpectedETH();
    }

    constructor(
        IUniswapV3Factory factory_
    ) Ownable(msg.sender) {
        factory = factory_;
    }

    /**
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
     * @param migrator Address of the migrator contract
     */
    function create(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 numTokensToSell,
        address numeraire,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint24 fee,
        address[] memory recipients,
        uint256[] memory amounts,
        ITokenFactory tokenFactory,
        bytes memory tokenData,
        IGovernanceFactory governanceFactory,
        bytes memory governanceData,
        IMigrator migrator
    ) external returns (address asset, address pool, address governance, address timelock) {
        require(getModuleState[address(tokenFactory)] == ModuleState.TokenFactory, WrongModuleState());
        require(getModuleState[address(governanceFactory)] == ModuleState.GovernanceFactory, WrongModuleState());
        require(getModuleState[address(migrator)] == ModuleState.Migrator, WrongModuleState());

        require(recipients.length == amounts.length, ArrayLengthsMismatch());

        uint256 totalToMint = numTokensToSell;
        for (uint256 i; i < amounts.length; i++) {
            totalToMint += amounts[i];
        }
        require(totalToMint == initialSupply, WrongInitialSupply());

        // asset = tokenFactory.create(name, symbol, initialSupply, address(this), address(this), pool, tokenData, salt);

        (governance, timelock) = governanceFactory.create(name, asset, governanceData);

        (address tokenA, address tokenB) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);
        pool = factory.getPool(tokenA, tokenB, 3000);
        if (pool == address(0)) pool = factory.createPool(tokenA, tokenB, 3000);

        address migratedPool = migrator.createPool(tokenA, tokenB);

        getTokenData[asset] = TokenData({
            numeraire: numeraire,
            governance: governance,
            recipients: recipients,
            amounts: amounts,
            migrator: migrator,
            timelock: timelock,
            pool: pool,
            migratedPool: migratedPool
        });

        IUniswapV3Pool(pool).initialize(sqrtPriceX96);

        uint256 amount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            asset == tokenA ? numTokensToSell : 0,
            asset == tokenA ? 0 : numTokensToSell
        );

        IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, amount, abi.encode(tokenA, tokenB));

        emit Create(asset, numeraire, pool);
    }

    // TODO: Add a check to ensure the pool we created is the actual msg.sender
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        (address tokenA, address tokenB) = abi.decode(data, (address, address));
        if (amount0Owed > 0) ERC20(tokenA).transfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) ERC20(tokenB).transfer(msg.sender, amount1Owed);
    }

    /**
     * @notice Triggers the migration from the Doppler hook to another liquidity pool
     * @param asset Address of the token to migrate
     */
    function migrate(
        address asset
    ) external {
        TokenData memory tokenData = getTokenData[asset];

        uint256 length = tokenData.recipients.length;
        for (uint256 i; i < length; i++) {
            ERC20(asset).transfer(tokenData.recipients[i], tokenData.amounts[i]);
        }

        DERC20(asset).unlockPool();
        uint256 price = IHook(address(tokenData.poolKey.hooks)).migrate(tokenData.timelock);
        Ownable(asset).transferOwnership(tokenData.timelock);

        (address pool,) = tokenData.migrator.migrate(
            Currency.unwrap(tokenData.poolKey.currency0),
            Currency.unwrap(tokenData.poolKey.currency1),
            price,
            tokenData.timelock,
            new bytes(0)
        );

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
