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

enum TokenState {
    Created,
    Staged,
    Seeded
}

contract Airlock is Ownable {
    PoolManager public immutable poolManager;

    mapping(address => FactoryState) public getFactoryState;
    mapping(address token => address hook) public getHookOf;

    constructor(PoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /**
     * @param tokenFactory Address of the factory contract deploying the ERC20 token
     * @param governanceFactory Minimal governance housing the Uniswap v2 LP tokens
     * @param liquidityFactory Address of the Uniswap v4 hook
     */
    function create(
        address tokenFactory,
        address governanceFactory,
        address liquidityFactory,
        address stageAdmin,
        uint256 liquidityAmount,
        address[] memory recipients,
        uint256[] memory amounts,
        bytes memory tokenInfo
    ) external returns (address tokenAddress) {
        require(getFactoryState[tokenFactory] == FactoryState.TokenFactory, WrongFactoryState());
        require(getFactoryState[governanceFactory] == FactoryState.GovernanceFactory, WrongFactoryState());
        require(getFactoryState[liquidityFactory] == FactoryState.LiquidityFactory, WrongFactoryState());
        tokenAddress = TokenFactory(tokenFactory).create("", "", 1_000_000_000e18, msg.sender);
        getHookOf[tokenAddress] = liquidityFactory;
    }

    // TODO: I think this function be just be called directly by `create`
    function stageLiquidity(address token, bytes memory hookData) external {
        PoolKey memory key = PoolKey({
            // TODO: Currently only ETH pairs are supported
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0, // TODO: Do we want users to have the ability to set the fee?
            tickSpacing: 60, // TODO: Do we want users to have the ability to set the tickSpacing?
            hooks: IHooks(getHookOf[token])
        });

        uint160 sqrtPriceX96;

        // TODO: We might want to call `approve` to let the hook take some of our tokens.
        poolManager.initialize(key, sqrtPriceX96, hookData);
    }

    function setFactoryState(address factory, FactoryState state) external onlyOwner {
        getFactoryState[factory] = state;
    }
}
