// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager, PoolKey, Currency, IHooks, TickMath} from "v4-core/src/PoolManager.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ITokenFactory} from "src/interfaces/ITokenFactory.sol";
import {IGovernanceFactory} from "src/interfaces/IGovernanceFactory.sol";
import {IHookFactory, IHook} from "src/interfaces/IHookFactory.sol";
import {IMigrator} from "src/interfaces/IMigrator.sol";

enum ModuleState {
    NotWhitelisted,
    TokenFactory,
    GovernanceFactory,
    HookFactory,
    Migrator
}

error WrongModuleState();

struct TokenData {
    address timelock;
    address governance;
    address hook;
    address[] recipients;
    uint256[] amounts;
    address migrator;
    address numeraire;
}

event Create(address asset, address indexed numeraire, address governance, address hook);

event Migrate(address asset, address pool);

event SetModuleState(address module, ModuleState state);

contract Airlock is Ownable {
    IPoolManager public immutable poolManager;

    mapping(address => ModuleState) public getModuleState;
    mapping(address token => TokenData) public getTokenData;

    receive() external payable {}

    constructor(IPoolManager poolManager_) Ownable(msg.sender) {
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
        // TODO: Maybe move all the parameters into the tokenData param?
        uint256 minimumProceeds,
        uint256 maximumProceeds,
        uint256 startingTime,
        uint256 endingTime,
        int24 minTick,
        int24 maxTick,
        uint256 epochLength,
        int24 gamma,
        address numeraire,
        address owner,
        address tokenFactory,
        bytes memory tokenData,
        address governanceFactory,
        bytes memory governanceData,
        address hookFactory,
        bytes memory hookData,
        address[] memory recipients,
        uint256[] memory amounts,
        address migrator
    ) external returns (address, address, address) {
        require(getModuleState[tokenFactory] == ModuleState.TokenFactory, WrongModuleState());
        require(getModuleState[governanceFactory] == ModuleState.GovernanceFactory, WrongModuleState());
        require(getModuleState[hookFactory] == ModuleState.HookFactory, WrongModuleState());
        require(getModuleState[migrator] == ModuleState.Migrator, WrongModuleState());

        uint256 totalToMint = initialSupply;
        for (uint256 i; i < amounts.length; i++) {
            totalToMint += amounts[i];
        }

        address token =
            ITokenFactory(tokenFactory).create(name, symbol, totalToMint, address(this), address(this), tokenData);

        bool isToken0 = token < numeraire ? true : false;

        // FIXME: We might want to double compare the minted / predicted addresses?
        (address predictedHook, bytes32 salt) = IHookFactory(hookFactory).predict(
            poolManager,
            initialSupply,
            minimumProceeds,
            maximumProceeds,
            startingTime,
            endingTime,
            isToken0 ? minTick : maxTick,
            isToken0 ? maxTick : minTick,
            epochLength,
            gamma,
            isToken0,
            hookData
        );
        address hook = IHookFactory(hookFactory).create(
            poolManager,
            initialSupply,
            minimumProceeds,
            maximumProceeds,
            startingTime,
            endingTime,
            isToken0 ? minTick : maxTick,
            isToken0 ? maxTick : minTick,
            epochLength,
            gamma,
            isToken0,
            hookData,
            salt
        );
        ERC20(token).transfer(hook, initialSupply);

        (address governance, address timelock) =
            IGovernanceFactory(governanceFactory).create(name, token, governanceData);
        Ownable(token).transferOwnership(timelock);

        getTokenData[token] = TokenData({
            governance: governance,
            hook: hook,
            recipients: recipients,
            amounts: amounts,
            migrator: migrator,
            timelock: timelock,
            numeraire: numeraire
        });

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(isToken0 ? token : numeraire),
            currency1: Currency.wrap(isToken0 ? numeraire : token),
            fee: 0, // TODO: Do we want users to have the ability to set the fee?
            tickSpacing: 60, // TODO: Do we want users to have the ability to set the tickSpacing?
            hooks: IHooks(hook)
        });

        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(isToken0 ? minTick : maxTick), new bytes(0));

        return (token, governance, hook);
    }

    function migrate(address asset) external {
        TokenData memory tokenData = getTokenData[asset];

        uint256 length = tokenData.recipients.length;
        for (uint256 i; i < length; i++) {
            ERC20(asset).transfer(tokenData.recipients[i], tokenData.amounts[i]);
        }

        (uint256 assetBalance, uint256 numeraireBalance) = IHook(tokenData.hook).migrate();
        (address pool,) = IMigrator(tokenData.migrator).migrate{
            value: asset < tokenData.numeraire ? 0 : numeraireBalance
        }(asset, getTokenData[asset].numeraire, assetBalance, numeraireBalance, tokenData.timelock, new bytes(0));
        emit Migrate(asset, pool);
    }

    // TODO: Maybe we should accept arrays here to batch update states?
    function setModuleState(address module, ModuleState state) external onlyOwner {
        getModuleState[module] = state;
        emit SetModuleState(module, state);
    }
}
