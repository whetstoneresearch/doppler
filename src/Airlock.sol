// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {TokenFactory} from "src/TokenFactory.sol";
import {Ownable} from "lib/solady/src/auth/Ownable.sol";

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
    mapping(address => FactoryState) public getFactoryState;
    mapping(address token => address hook) public getHookOf;

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

    // TODO: Add hook parameters
    function stageLiquidity(address token) external {
        // I think the flow would be something like:
        // user -> Airlock -> PoolManager -> Hook (via beforeInitialize)
    }

    function setFactoryState(address factory, FactoryState state) external onlyOwner {
        getFactoryState[factory] = state;
    }
}
