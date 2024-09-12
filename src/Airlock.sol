// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenFactory} from "src/TokenFactory.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {PoolManager, PoolKey, Currency, IHooks} from "v4-core/src/PoolManager.sol";

enum FactoryState {
    NotWhitelisted,
    TokenFactory,
    GovernanceFactory,
    LiquidityFactory
}

error WrongFactoryState();

struct Token {
    address governance;
    bool hasMigrated;
    address hook;
}

contract Airlock is Ownable {
    PoolManager public immutable poolManager;

    mapping(address => FactoryState) public getFactoryState;
    mapping(address tokenAddress => Token) public getToken;

    constructor(PoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /**
     * TODO:
     * - Creating a token should incur fees (platform and frontend fees)
     *
     * @param tokenFactory Address of the factory contract deploying the ERC20 token
     * @param governanceFactory Minimal governance housing the Uniswap v2 LP tokens
     * @param liquidityFactory Address of the Uniswap v4 hook
     */
    function create(
        address tokenFactory,
        address governanceFactory,
        address liquidityFactory,
        uint256 liquidityAmount,
        address stageAdmin,
        address[] memory recipients,
        uint256[] memory amounts,
        string memory name,
        string memory symbol,
        bytes memory hookData
    ) external returns (address tokenAddress) {
        require(getFactoryState[tokenFactory] == FactoryState.TokenFactory, WrongFactoryState());
        require(getFactoryState[governanceFactory] == FactoryState.GovernanceFactory, WrongFactoryState());
        require(getFactoryState[liquidityFactory] == FactoryState.LiquidityFactory, WrongFactoryState());
        tokenAddress = TokenFactory(tokenFactory).create(name, symbol, 1_000_000_000e18, msg.sender); // TODO: Define the total supply

        getToken[tokenAddress] = Token({
            governance: address(0), // TODO: Deploy a minimal governance contract
            hasMigrated: false,
            hook: liquidityFactory
        });

        PoolKey memory key = PoolKey({
            // TODO: Currently only ETH pairs are supported
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(tokenAddress),
            fee: 0, // TODO: Do we want users to have the ability to set the fee?
            tickSpacing: 60, // TODO: Do we want users to have the ability to set the tickSpacing?
            hooks: IHooks(liquidityFactory)
        });

        uint160 sqrtPriceX96;

        // TODO: We might want to call `approve` to let the hook take some of our tokens.
        poolManager.initialize(key, sqrtPriceX96, hookData);
    }

    function setFactoryState(address factory, FactoryState state) external onlyOwner {
        getFactoryState[factory] = state;
    }
}
