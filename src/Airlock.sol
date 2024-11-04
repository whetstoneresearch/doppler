// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IPoolManager, PoolKey, Currency, TickMath } from "v4-core/src/PoolManager.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IHookFactory, IHook } from "src/interfaces/IHookFactory.sol";
import { IMigrator } from "src/interfaces/IMigrator.sol";

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

contract Airlock is Ownable {
    IPoolManager public immutable poolManager;

    mapping(address => ModuleState) public getModuleState;
    mapping(address token => TokenData) public getTokenData;

    receive() external payable { }

    constructor(
        IPoolManager poolManager_
    ) Ownable(msg.sender) {
        poolManager = poolManager_;
    }

    /**
     * TODO:
     * - Creating a token should incur fees (platform and frontend fees)
     *
     * @param tokenFactory Address of the factory contract deploying the ERC20 token
     * @param governanceFactory Address of the factory contract deploying the governance
     * @param hookFactory Address of the factory contract deploying the Uniswap v4 hook
     */
    function create(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 numTokensToSell,
        PoolKey memory poolKey,
        address owner,
        address[] memory recipients,
        uint256[] memory amounts,
        ITokenFactory tokenFactory,
        bytes memory tokenData,
        IGovernanceFactory governanceFactory,
        bytes memory governanceData,
        IHookFactory hookFactory,
        bytes memory hookData,
        IMigrator migrator,
        bytes32 salt
    ) external returns (address, address, address) {
        require(getModuleState[address(tokenFactory)] == ModuleState.TokenFactory, WrongModuleState());
        require(getModuleState[address(governanceFactory)] == ModuleState.GovernanceFactory, WrongModuleState());
        require(getModuleState[address(hookFactory)] == ModuleState.HookFactory, WrongModuleState());
        require(getModuleState[address(migrator)] == ModuleState.Migrator, WrongModuleState());

        require(recipients.length == amounts.length, ArrayLengthsMismatch());

        uint256 totalToMint = numTokensToSell;
        for (uint256 i; i < amounts.length; i++) {
            totalToMint += amounts[i];
        }
        require(totalToMint == initialSupply, WrongInitialSupply());

        address token = tokenFactory.create(name, symbol, initialSupply, address(this), address(this), tokenData, salt);
        address hook = hookFactory.create(poolManager, numTokensToSell, hookData, salt);

        ERC20(token).transfer(hook, numTokensToSell);

        // TODO: I don't think we need to pass the salt here, create2 is not needed anyway.
        (address governance, address timelock) = governanceFactory.create(name, token, governanceData);
        Ownable(token).transferOwnership(timelock);

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
     * @notice Triggers the migration from the Doppler hook to another liquidity pool.
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

        (uint256 amount0, uint256 amount1) = IHook(address(tokenData.poolKey.hooks)).migrate();

        address currency0 = Currency.unwrap(tokenData.poolKey.currency0);
        address currency1 = Currency.unwrap(tokenData.poolKey.currency1);

        if (currency0 != address(0)) ERC20(currency0).transfer(address(tokenData.migrator), amount0);
        ERC20(currency1).transfer(address(tokenData.migrator), amount1);

        (address pool,) = tokenData.migrator.migrate{ value: currency0 == address(0) ? amount0 : 0 }(
            currency0, currency1, amount0, amount1, tokenData.timelock, new bytes(0)
        );

        emit Migrate(asset, pool);
    }

    /**
     * @notice Sets the state of the givens modules.
     * @param modules Array of module addresses.
     * @param states Array of module states.
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
