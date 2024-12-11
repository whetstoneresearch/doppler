// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager, PoolKey, TickMath } from "v4-core/src/PoolManager.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IHookFactory, IHook } from "src/interfaces/IHookFactory.sol";
import { IMigrator } from "src/interfaces/IMigrator.sol";
import { lessThan, Currency } from "v4-core/src/types/Currency.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { DERC20 } from "src/DERC20.sol";

enum ModuleState {
    NotWhitelisted,
    TokenFactory,
    GovernanceFactory,
    HookFactory,
    Migrator
}

error WrongModuleState();

error WrongInitialSupply();

error ArrayLengthsMismatch();

error InvalidPoolKey();
error TokenNotInPoolKey();
error HookNotInPoolKey();

struct TokenData {
    PoolKey poolKey;
    address timelock;
    address governance;
    IMigrator migrator;
    address[] recipients;
    uint256[] amounts;
}

event Create(address asset, PoolKey poolKey, address hook);

event Migrate(address asset, address pool);

event SetModuleState(address module, ModuleState state);

/// @custom:security-contact security@whetstone.cc
contract Airlock is Ownable {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    mapping(address => ModuleState) public getModuleState;
    mapping(address token => TokenData) public getTokenData;

    receive() external payable { }

    /// @param poolManager_ Address of the Uniswap V4 pool manager
    constructor(
        IPoolManager poolManager_
    ) Ownable(msg.sender) {
        poolManager = poolManager_;
    }

    /**
     * TODO:
     * - Creating a token should incur fees (platform and frontend fees)
     *
     * @notice Deploys a new token with the associated governance, timelock and hook contracts
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param initialSupply Total supply of the token (might be increased later on)
     * @param numTokensToSell Amount of tokens to sell in the Doppler hook
     * @param poolKey Pool key of the liquidity pool (precomputed)
     * @param recipients Array of addresses to receive tokens after the migration
     * @param amounts Array of amounts to receive after the migration
     * @param tokenFactory Address of the factory contract deploying the ERC20 token
     * @param tokenData Arbitrary data to pass to the token factory
     * @param governanceFactory Address of the factory contract deploying the governance
     * @param governanceData Arbitrary data to pass to the governance factory
     * @param hookFactory Address of the factory contract deploying the Uniswap v4 hook
     * @param hookData Arbitrary data to pass to the hook factory
     * @param migrator Address of the migrator contract
     * @param salt Salt to use for the create2 calls
     */
    function create(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 numTokensToSell,
        PoolKey memory poolKey,
        address[] memory recipients,
        uint256[] memory amounts,
        ITokenFactory tokenFactory,
        bytes memory tokenData,
        IGovernanceFactory governanceFactory,
        bytes memory governanceData,
        IHookFactory hookFactory,
        bytes memory hookData,
        IMigrator migrator,
        address pool,
        bytes32 salt
    ) external returns (address, address, address) {
        require(getModuleState[address(tokenFactory)] == ModuleState.TokenFactory, WrongModuleState());
        require(getModuleState[address(governanceFactory)] == ModuleState.GovernanceFactory, WrongModuleState());
        require(getModuleState[address(hookFactory)] == ModuleState.HookFactory, WrongModuleState());
        require(getModuleState[address(migrator)] == ModuleState.Migrator, WrongModuleState());

        require(recipients.length == amounts.length, ArrayLengthsMismatch());

        require(lessThan(poolKey.currency0, poolKey.currency1), InvalidPoolKey());

        uint256 totalToMint = numTokensToSell;
        for (uint256 i; i < amounts.length; ++i) {
            totalToMint += amounts[i];
        }
        require(totalToMint == initialSupply, WrongInitialSupply());

        address token =
            tokenFactory.create(name, symbol, initialSupply, address(this), address(this), pool, tokenData, salt);
        address hook = hookFactory.create(poolManager, numTokensToSell, hookData, salt);

        require(
            token == Currency.unwrap(poolKey.currency0) || token == Currency.unwrap(poolKey.currency1),
            TokenNotInPoolKey()
        );
        require(hook == address(poolKey.hooks), HookNotInPoolKey());

        ERC20(token).transfer(hook, numTokensToSell);

        // TODO: I don't think we need to pass the salt here, create2 is not needed anyway
        (address governance, address timelock) = governanceFactory.create(name, token, governanceData);

        migrator.createPool(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));

        getTokenData[token] = TokenData({
            governance: governance,
            recipients: recipients,
            amounts: amounts,
            migrator: migrator,
            timelock: timelock,
            poolKey: poolKey
        });

        // TODO: Do we really have to initialize the pool at the right price?
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0), new bytes(0));

        emit Create(token, poolKey, hook);

        return (token, governance, hook);
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
        for (uint256 i; i < length; ++i) {
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

        for (uint256 i; i < length; ++i) {
            getModuleState[modules[i]] = states[i];
            emit SetModuleState(modules[i], states[i]);
        }
    }
}
