// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IPoolManager, PoolKey, Currency, IHooks} from "v4-core/src/PoolManager.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
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
}

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
        address tokenFactory,
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address owner,
        bytes memory tokenData,
        address governanceFactory,
        bytes memory governanceData,
        address hookFactory,
        bytes memory hookData,
        uint256 liquidityAmount,
        address stageAdmin,
        address[] memory recipients,
        uint256[] memory amounts
    ) external returns (address token, address governance, address hook) {
        require(getFactoryState[tokenFactory] == FactoryState.TokenFactory, WrongFactoryState());
        require(getFactoryState[governanceFactory] == FactoryState.GovernanceFactory, WrongFactoryState());
        require(getFactoryState[hookFactory] == FactoryState.HookFactory, WrongFactoryState());

        // FIXME: Address of the hook is unknown at this point
        token = ITokenFactory(tokenFactory).create(name, symbol, totalSupply, hook, owner, tokenData);
        (governance,) = IGovernanceFactory(governanceFactory).create(token, governanceData);
        hook = IHookFactory(hookFactory).create(poolManager, hookData);

        getToken[token] = Token({governance: governance, hasMigrated: false, hook: hook});

        PoolKey memory key = PoolKey({
            // TODO: Currently only ETH pairs are supported
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0, // TODO: Do we want users to have the ability to set the fee?
            tickSpacing: 60, // TODO: Do we want users to have the ability to set the tickSpacing?
            hooks: IHooks(hook)
        });

        uint160 sqrtPriceX96;

        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
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
