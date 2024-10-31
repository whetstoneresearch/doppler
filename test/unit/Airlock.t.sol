/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {Airlock, ModuleState, SetModuleState} from "src/Airlock.sol";
import {TokenFactory} from "src/TokenFactory.sol";
import {DopplerFactory} from "src/DopplerFactory.sol";
import {GovernanceFactory} from "src/GovernanceFactory.sol";
import {UniswapV2Migrator} from "src/UniswapV2Migrator.sol";

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

contract AirlockTest is Test, Deployers {
    Airlock airlock;
    TokenFactory tokenFactory;
    DopplerFactory dopplerFactory;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator migrator;

    function setUp() public {
        deployFreshManager();
        airlock = new Airlock(manager);
        tokenFactory = new TokenFactory();
        dopplerFactory = new DopplerFactory();
        governanceFactory = new GovernanceFactory();

        airlock.setModuleState(address(tokenFactory), ModuleState.TokenFactory);
        airlock.setModuleState(address(dopplerFactory), ModuleState.HookFactory);
        airlock.setModuleState(address(governanceFactory), ModuleState.GovernanceFactory);
        airlock.setModuleState(address(migrator), ModuleState.Migrator);
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

    function test_create_Deploys() public {
        (bytes32 salt, address hook, address token) = mine(
            address(dopplerFactory),
            MineParams({
                poolManager: address(manager),
                numTokensToSell: DEFAULT_INITIAL_SUPPLY,
                minTick: DEFAULT_START_TICK,
                maxTick: DEFAULT_END_TICK,
                airlock: address(airlock),
                name: DEFAULT_TOKEN_NAME,
                symbol: DEFAULT_TOKEN_SYMBOL,
                initialSupply: DEFAULT_INITIAL_SUPPLY,
                recipient: address(this),
                owner: address(this),
                numeraire: address(0),
                startingTime: DEFAULT_STARTING_TIME,
                endingTime: DEFAULT_ENDING_TIME,
                minimumProceeds: DEFAULT_MIN_PROCEEDS,
                maximumProceeds: DEFAULT_MAX_PROCEEDS,
                epochLength: DEFAULT_EPOCH_LENGTH,
                gamma: DEFAULT_GAMMA,
                numPDSlugs: 3
            })
        );

        console.log("hook: %s", hook);
        console.log("token: %s", token);

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
            3
        );

        airlock.create(
            DEFAULT_TOKEN_NAME,
            DEFAULT_TOKEN_SYMBOL,
            DEFAULT_INITIAL_SUPPLY,
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
}
