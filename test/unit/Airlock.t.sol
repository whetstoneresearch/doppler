/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {console} from "forge-std/console.sol";

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {Airlock, ModuleState, WrongModuleState, SetModuleState, WrongInitialSupply} from "src/Airlock.sol";
import {TokenFactory} from "src/TokenFactory.sol";
import {DopplerFactory} from "src/DopplerFactory.sol";
import {GovernanceFactory} from "src/GovernanceFactory.sol";
import {UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory} from "src/UniswapV2Migrator.sol";

import {mine, MineParams} from "test/shared/AirlockMiner.sol";

// TODO: Reuse these constants from the BaseTest
string constant DEFAULT_TOKEN_NAME = "Test";
string constant DEFAULT_TOKEN_SYMBOL = "TST";
uint256 constant DEFAULT_INITIAL_SUPPLY = 1e27;
uint256 constant DEFAULT_MIN_PROCEEDS = 1 ether;
uint256 constant DEFAULT_MAX_PROCEEDS = 10 ether;
uint256 constant DEFAULT_STARTING_TIME = 1 days;
uint256 constant DEFAULT_ENDING_TIME = 3 days;
int24 constant DEFAULT_GAMMA = 800;
uint256 constant DEFAULT_EPOCH_LENGTH = 400 seconds;
address constant DEFAULT_OWNER = address(0xdeadbeef);

int24 constant DEFAULT_START_TICK = 1600;
int24 constant DEFAULT_END_TICK = 171_200;

uint24 constant DEFAULT_FEE = 0;
int24 constant DEFAULT_TICK_SPACING = 8;

uint256 constant DEFAULT_PD_SLUGS = 3;

address constant uniRouterV2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant uniFactoryV2 = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

contract AirlockTest is Test, Deployers {
    Airlock airlock;
    TokenFactory tokenFactory;
    DopplerFactory dopplerFactory;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator migrator;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21093509);
        vm.warp(DEFAULT_STARTING_TIME);
        deployFreshManager();
        airlock = new Airlock(manager);
        tokenFactory = new TokenFactory();
        dopplerFactory = new DopplerFactory();
        governanceFactory = new GovernanceFactory();

        airlock.setModuleState(address(tokenFactory), ModuleState.TokenFactory);
        airlock.setModuleState(address(dopplerFactory), ModuleState.HookFactory);
        airlock.setModuleState(address(governanceFactory), ModuleState.GovernanceFactory);

        migrator = new UniswapV2Migrator(IUniswapV2Factory(uniFactoryV2), IUniswapV2Router02(uniRouterV2));
        airlock.setModuleState(address(migrator), ModuleState.Migrator);
    }

    function _getDefaultMineParams() public view returns (MineParams memory) {
        // We're using a function here because some values are set by the `setUp` function.
        return MineParams({
            poolManager: address(manager),
            numTokensToSell: DEFAULT_INITIAL_SUPPLY,
            minTick: DEFAULT_START_TICK,
            maxTick: DEFAULT_END_TICK,
            airlock: address(airlock),
            name: DEFAULT_TOKEN_NAME,
            symbol: DEFAULT_TOKEN_SYMBOL,
            initialSupply: DEFAULT_INITIAL_SUPPLY,
            numeraire: address(0), // Using ETH
            startingTime: DEFAULT_STARTING_TIME,
            endingTime: DEFAULT_ENDING_TIME,
            minimumProceeds: DEFAULT_MIN_PROCEEDS,
            maximumProceeds: DEFAULT_MAX_PROCEEDS,
            epochLength: DEFAULT_EPOCH_LENGTH,
            gamma: DEFAULT_GAMMA,
            numPDSlugs: DEFAULT_PD_SLUGS
        });
    }

    function test_setModuleState_SetsState() public {
        airlock.setModuleState(address(0xbeef), ModuleState.TokenFactory);
        assertEq(uint8(airlock.getModuleState(address(0xbeef))), uint8(ModuleState.TokenFactory));
    }

    function test_setModuleState_EmitsEvent() public {
        vm.expectEmit();
        emit SetModuleState(address(0xbeef), ModuleState.TokenFactory);
        airlock.setModuleState(address(0xbeef), ModuleState.TokenFactory);
    }

    function test_setModuleState_RevertsWhenSenderNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xb0b)));
        vm.prank(address(0xb0b));
        airlock.setModuleState(address(0xbeef), ModuleState.TokenFactory);
    }

    function _create() internal returns (address, address) {
        return _create(_getDefaultMineParams());
    }

    function _create(MineParams memory params) internal returns (address, address) {
        (bytes32 salt, address hook, address token) = mine(address(tokenFactory), address(dopplerFactory), params);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(hook)
        });

        bytes memory hookFactoryData = abi.encode(
            params.minimumProceeds,
            params.maximumProceeds,
            params.startingTime,
            params.endingTime,
            params.minTick,
            params.maxTick,
            params.epochLength,
            params.gamma,
            false,
            params.numPDSlugs
        );

        airlock.create(
            params.name,
            params.symbol,
            params.initialSupply,
            params.numTokensToSell,
            poolKey,
            DEFAULT_OWNER,
            new address[](0),
            new uint256[](0),
            tokenFactory,
            new bytes(0),
            governanceFactory,
            new bytes(0),
            dopplerFactory,
            hookFactoryData,
            migrator,
            salt
        );

        return (hook, token);
    }

    function test_create_Deploys() public {
        _create();
    }

    function test_create_MintsTokens() public {
        (address hook, address token) = _create();
        assertEq(ERC20(token).totalSupply(), DEFAULT_INITIAL_SUPPLY);
        assertEq(ERC20(token).balanceOf(hook), DEFAULT_INITIAL_SUPPLY);
    }

    function test_migrate() public {
        (, address token) = _create();

        airlock.migrate(token);
    }

    function test_create_RevertsIfWrongTokenFactory() public {
        airlock.setModuleState(address(tokenFactory), ModuleState.NotWhitelisted);
        vm.expectRevert(WrongModuleState.selector);
        _create();
    }

    function test_create_RevertsIfWrongGovernanceFactory() public {
        airlock.setModuleState(address(governanceFactory), ModuleState.NotWhitelisted);
        vm.expectRevert(WrongModuleState.selector);
        _create();
    }

    function test_create_RevertsIfWrongHookFactory() public {
        airlock.setModuleState(address(dopplerFactory), ModuleState.NotWhitelisted);
        vm.expectRevert(WrongModuleState.selector);
        _create();
    }

    function test_create_RevertsIfWrongMigrator() public {
        airlock.setModuleState(address(migrator), ModuleState.NotWhitelisted);
        vm.expectRevert(WrongModuleState.selector);
        _create();
    }

    // TODO: These tests are pretty heavy, let's see if we can make a function to simplify them.
    function test_create_RevertsIfWrongInitialSupply() public {
        {
            MineParams memory params = _getDefaultMineParams();
            // Trying to mint more tokens than the amount to sell.
            params.initialSupply = DEFAULT_INITIAL_SUPPLY + 1;

            (bytes32 salt, address hook, address token) = mine(address(tokenFactory), address(dopplerFactory), params);

            PoolKey memory poolKey = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: DEFAULT_FEE,
                tickSpacing: DEFAULT_TICK_SPACING,
                hooks: IHooks(hook)
            });

            bytes memory hookFactoryData = abi.encode(
                DEFAULT_MIN_PROCEEDS,
                DEFAULT_MAX_PROCEEDS,
                DEFAULT_STARTING_TIME,
                DEFAULT_ENDING_TIME,
                DEFAULT_START_TICK,
                DEFAULT_END_TICK,
                DEFAULT_EPOCH_LENGTH,
                DEFAULT_GAMMA,
                false,
                DEFAULT_PD_SLUGS
            );

            vm.expectRevert(WrongInitialSupply.selector);
            airlock.create(
                params.name,
                params.symbol,
                params.initialSupply,
                params.numTokensToSell,
                poolKey,
                DEFAULT_OWNER,
                new address[](0),
                new uint256[](0),
                tokenFactory,
                new bytes(0),
                governanceFactory,
                new bytes(0),
                dopplerFactory,
                hookFactoryData,
                migrator,
                salt
            );
        }

        {
            // Trying to allocate too many tokens to the team.
            uint256[] memory amounts = new uint256[](4);
            address[] memory recipients = new address[](4);

            for (uint256 i; i < amounts.length; i++) {
                amounts[i] = 10_000 ether;
            }

            (bytes32 salt, address hook, address token) =
                mine(address(tokenFactory), address(dopplerFactory), _getDefaultMineParams());

            PoolKey memory poolKey = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(token),
                fee: DEFAULT_FEE,
                tickSpacing: DEFAULT_TICK_SPACING,
                hooks: IHooks(hook)
            });

            bytes memory hookFactoryData = abi.encode(
                DEFAULT_MIN_PROCEEDS,
                DEFAULT_MAX_PROCEEDS,
                DEFAULT_STARTING_TIME,
                DEFAULT_ENDING_TIME,
                DEFAULT_START_TICK,
                DEFAULT_END_TICK,
                DEFAULT_EPOCH_LENGTH,
                DEFAULT_GAMMA,
                false,
                DEFAULT_PD_SLUGS
            );

            vm.expectRevert(WrongInitialSupply.selector);
            airlock.create(
                DEFAULT_TOKEN_NAME,
                DEFAULT_TOKEN_SYMBOL,
                DEFAULT_INITIAL_SUPPLY,
                DEFAULT_INITIAL_SUPPLY,
                poolKey,
                DEFAULT_OWNER,
                recipients,
                amounts,
                tokenFactory,
                new bytes(0),
                governanceFactory,
                new bytes(0),
                dopplerFactory,
                hookFactoryData,
                migrator,
                salt
            );
        }
    }
}
