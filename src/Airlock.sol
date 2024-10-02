// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager, PoolKey, Currency, IHooks, TickMath} from "v4-core/src/PoolManager.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {ITokenFactory} from "src/interfaces/ITokenFactory.sol";
import {IGovernanceFactory} from "src/interfaces/IGovernanceFactory.sol";
import {IHookFactory} from "src/interfaces/IHookFactory.sol";

enum FactoryState {
    NotWhitelisted,
    TokenFactory,
    GovernanceFactory,
    HookFactory
}

error WrongFactoryState();

struct Token {
    address governance;
    bool hasMigrated;
    address hook;
    address[] recipients;
    uint256[] amounts;
}

event Create(address asset, address indexed numeraire, address governance, address hook);

contract Airlock is Ownable {
    IPoolManager public immutable poolManager;

    mapping(address => FactoryState) public getFactoryState;
    mapping(address => Token) public getToken;

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
        uint256 totalSupply,
        uint256 startingTime,
        uint256 endingTime,
        address numeraire,
        address owner,
        address tokenFactory,
        bytes memory tokenData,
        address governanceFactory,
        bytes memory governanceData,
        address hookFactory,
        bytes memory hookData,
        address[] memory recipients,
        uint256[] memory amounts
    ) external returns (address, address, address) {
        // The following parameters are hardcoded for now, let's decide if we want to let the user set them:
        int24 minTick = -100_000;
        int24 maxTick = 200_000;
        uint256 epochLength = 50;
        uint256 gamma = 1_000;

        require(getFactoryState[tokenFactory] == FactoryState.TokenFactory, WrongFactoryState());
        require(getFactoryState[governanceFactory] == FactoryState.GovernanceFactory, WrongFactoryState());
        require(getFactoryState[hookFactory] == FactoryState.HookFactory, WrongFactoryState());

        // FIXME: For now we're transferring the whole supply into this contract + receiving the ownership
        address token =
            ITokenFactory(tokenFactory).create(name, symbol, totalSupply, address(this), address(this), tokenData);

        bool isToken0 = token < numeraire ? true : false;

        // FIXME: We might want to double compare the minted / predicted addresses?
        (address predictedHook, bytes32 salt) = IHookFactory(hookFactory).predict(
            poolManager,
            totalSupply / 2,
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
            totalSupply / 2,
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
        ERC20(token).transfer(hook, totalSupply / 2);

        (address governance,) = IGovernanceFactory(governanceFactory).create(name, token, governanceData);
        // FIXME: I think the Timelock should be the owner of the token contract?
        Ownable(token).transferOwnership(governance);

        getToken[token] =
            Token({governance: governance, hasMigrated: false, hook: hook, recipients: recipients, amounts: amounts});

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

    /**
     * TODO: This function will be callable later by the hook contract itself, in order to move the liquidity
     * from the Uniswap v4 pool to a v2 pool. The flow would be something like:
     * 1) Enough tokens were sold to trigger the migration
     * 2) Hook contract will remove its positions
     */
    function migrate() external {}

    function setFactoryState(address factory, FactoryState state) external onlyOwner {
        getFactoryState[factory] = state;
    }
}
