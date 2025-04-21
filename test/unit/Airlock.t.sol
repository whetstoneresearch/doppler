// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test, stdError } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import {
    Airlock,
    ModuleState,
    WrongModuleState,
    SetModuleState,
    CreateParams,
    Collect,
    ArrayLengthsMismatch,
    AssetData,
    Migrate
} from "src/Airlock.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { DERC20, ERC20 } from "src/DERC20.sol";
import { UniswapV4Initializer, DopplerDeployer } from "src/UniswapV4Initializer.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory } from "src/UniswapV2Migrator.sol";
import { InitData, UniswapV3Initializer, IUniswapV3Factory } from "src/UniswapV3Initializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { mineV4, MineV4Params } from "test/shared/AirlockMiner.sol";
import { UNISWAP_V2_ROUTER_MAINNET, UNISWAP_V2_FACTORY_MAINNET, WETH_MAINNET } from "test/shared/Addresses.sol";

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
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.23 ether;

int24 constant DEFAULT_START_TICK = 6000;
int24 constant DEFAULT_END_TICK = 60_000;

uint24 constant DEFAULT_FEE = 0;
int24 constant DEFAULT_TICK_SPACING = 8;

uint256 constant DEFAULT_PD_SLUGS = 3;

/// @dev Test contract allowing us to set some specific state
contract AirlockCheat is Airlock {
    constructor(
        address owner_
    ) Airlock(owner_) { }

    function setProtocolFees(address token, uint256 amount) public {
        getProtocolFees[token] = amount;
    }

    function setIntegratorFees(address integrator, address token, uint256 amount) public {
        getIntegratorFees[integrator][token] = amount;
    }

    function setAssetData(address asset, AssetData memory data) public {
        getAssetData[asset] = data;
    }
}

contract MockLiquidityMigrator is ILiquidityMigrator {
    function initialize(address, address, bytes calldata) external override returns (address) { }

    function migrate(
        uint160 sqrtPriceX96,
        address token0,
        address token1,
        address timelock
    ) external payable override returns (uint256) {
        // Do nothing
    }
}

contract AirlockTest is Test, Deployers {
    AirlockCheat airlock;
    TokenFactory tokenFactory;
    UniswapV4Initializer uniswapV4Initializer;
    DopplerDeployer deployer;
    UniswapV3Initializer uniswapV3Initializer;
    GovernanceFactory governanceFactory;
    UniswapV2Migrator uniswapV2LiquidityMigrator;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        vm.warp(DEFAULT_STARTING_TIME);

        deployFreshManager();

        airlock = new AirlockCheat(address(this));
        tokenFactory = new TokenFactory(address(airlock));
        deployer = new DopplerDeployer(manager);
        uniswapV4Initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        uniswapV3Initializer =
            new UniswapV3Initializer(address(airlock), IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984));
        governanceFactory = new GovernanceFactory(address(airlock));
        uniswapV2LiquidityMigrator = new UniswapV2Migrator(
            address(airlock),
            IUniswapV2Factory(UNISWAP_V2_FACTORY_MAINNET),
            IUniswapV2Router02(UNISWAP_V2_ROUTER_MAINNET),
            address(0xb055)
        );

        address[] memory modules = new address[](5);
        modules[0] = address(tokenFactory);
        modules[1] = address(uniswapV3Initializer);
        modules[2] = address(uniswapV4Initializer);
        modules[3] = address(governanceFactory);
        modules[4] = address(uniswapV2LiquidityMigrator);

        ModuleState[] memory states = new ModuleState[](5);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.GovernanceFactory;
        states[4] = ModuleState.LiquidityMigrator;

        airlock.setModuleState(modules, states);
    }

    function test_setModuleState_SetsState() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0xbeef);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.TokenFactory;

        airlock.setModuleState(modules, states);
        assertEq(uint8(airlock.getModuleState(address(0xbeef))), uint8(ModuleState.TokenFactory));
    }

    function test_setModuleState_EmitsEvent() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0xbeef);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.TokenFactory;

        vm.expectEmit();
        emit SetModuleState(address(0xbeef), ModuleState.TokenFactory);
        airlock.setModuleState(modules, states);
    }

    function test_setModuleState_RevertsWhenSenderNotOwner() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0xbeef);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.TokenFactory;

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xb0b)));
        vm.prank(address(0xb0b));
        airlock.setModuleState(modules, states);
    }

    function test_setModuleState_RevertsWhenArrayLengthsMismatch() public {
        address[] memory modules = new address[](1);
        modules[0] = address(0xbeef);
        ModuleState[] memory states = new ModuleState[](2);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.PoolInitializer;

        vm.expectRevert(ArrayLengthsMismatch.selector);
        airlock.setModuleState(modules, states);
    }

    // TODO: It would be better to move this into an integration test
    function test_create_DeploysV4() public returns (address, address) {
        bytes memory tokenFactoryData =
            abi.encode(DEFAULT_TOKEN_NAME, DEFAULT_TOKEN_SYMBOL, 0, 0, new address[](0), new uint256[](0), "");

        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(DEFAULT_START_TICK);

        bytes memory poolInitializerData = abi.encode(
            sqrtPrice,
            DEFAULT_MIN_PROCEEDS,
            DEFAULT_MAX_PROCEEDS,
            DEFAULT_STARTING_TIME,
            DEFAULT_ENDING_TIME,
            DEFAULT_START_TICK,
            DEFAULT_END_TICK,
            DEFAULT_EPOCH_LENGTH,
            DEFAULT_GAMMA,
            false,
            DEFAULT_PD_SLUGS,
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING
        );

        (bytes32 salt, address hook, address asset) = mineV4(
            MineV4Params(
                address(airlock),
                address(manager),
                DEFAULT_INITIAL_SUPPLY,
                DEFAULT_INITIAL_SUPPLY,
                address(0),
                tokenFactory,
                tokenFactoryData,
                uniswapV4Initializer,
                poolInitializerData
            )
        );

        airlock.create(
            CreateParams(
                DEFAULT_INITIAL_SUPPLY,
                DEFAULT_INITIAL_SUPPLY,
                address(0),
                tokenFactory,
                tokenFactoryData,
                governanceFactory,
                abi.encode(DEFAULT_TOKEN_NAME, 7200, 50_400, 0),
                uniswapV4Initializer,
                poolInitializerData,
                uniswapV2LiquidityMigrator,
                new bytes(0),
                address(0xb0b),
                salt
            )
        );

        return (hook, asset);
    }

    address public constant DEFAULT_INTEGRATOR = address(0x0000000aaaaabbbcccceee);

    function test_migrate_DistributeFees(uint128 fees0, uint128 balance0, uint128 fees1, uint128 balance1) public {
        vm.assume(fees0 < balance0);
        vm.assume(fees1 < balance1);

        address token0 = address(0xa005);
        address token1 = address(0xa006);

        (uint256 protocolFees0, uint256 integratorFees0) = _computeFees(fees0, balance0);
        (uint256 protocolFees1, uint256 integratorFees1) = _computeFees(fees1, balance1);

        _migrate(token0, fees0, balance0, token1, fees1, balance1);

        assertEq(airlock.getProtocolFees(token0), protocolFees0, "Wrong protocolFees0");
        assertEq(airlock.getProtocolFees(token1), protocolFees1, "Wrong protocolFees1");
        assertEq(airlock.getIntegratorFees(DEFAULT_INTEGRATOR, token0), integratorFees0, "Wrong integratorFees0");
        assertEq(airlock.getIntegratorFees(DEFAULT_INTEGRATOR, token1), integratorFees1, "Wrong integratorFees1");
    }

    function _computeFees(
        uint256 fees,
        uint256 balance
    ) internal pure returns (uint256 protocolFees, uint256 integratorFees) {
        if (fees > 0) {
            uint256 protocolLpFees = fees / 20;
            uint256 protocolProceedsFees = (balance - fees) / 1000;
            protocolFees = protocolLpFees > protocolProceedsFees ? protocolLpFees : protocolProceedsFees;
            uint256 maxProtocolFees = fees / 5;
            (integratorFees, protocolFees) = protocolFees > maxProtocolFees
                ? (fees - maxProtocolFees, maxProtocolFees)
                : (fees - protocolFees, protocolFees);
        }
    }

    function test_migrate_NoLPFees() public {
        address token0 = address(0xa005);
        uint128 fees0 = 0 ether;
        uint128 balance0 = 1 ether;
        address token1 = address(0xa006);
        uint128 fees1 = 0 ether;
        uint128 balance1 = 1 ether;

        _migrate(token0, fees0, balance0, token1, fees1, balance1);

        assertEq(airlock.getProtocolFees(token0), 0, "Wrong protocolFees0");
        assertEq(airlock.getProtocolFees(token1), 0, "Wrong protocolFees1");
        assertEq(airlock.getIntegratorFees(DEFAULT_INTEGRATOR, token0), 0, "Wrong integratorFees0");
        assertEq(airlock.getIntegratorFees(DEFAULT_INTEGRATOR, token1), 0, "Wrong integratorFees1");
    }

    function test_migrate_HardcodedFees() public {
        address token0 = address(0xa005);
        uint128 fees0 = 0.01 ether;
        uint128 balance0 = 1 ether;
        address token1 = address(0xa006);
        uint128 fees1 = 0.01 ether;
        uint128 balance1 = 1 ether;

        _migrate(token0, fees0, balance0, token1, fees1, balance1);

        uint256 protocolFees0 = 990_000_000_000_000;
        uint256 protocolFees1 = 990_000_000_000_000;
        uint256 integratorFees0 = fees0 - protocolFees0;
        uint256 integratorFees1 = fees1 - protocolFees1;

        assertEq(airlock.getProtocolFees(token0), protocolFees0, "Wrong protocolFees0");
        assertEq(airlock.getProtocolFees(token1), protocolFees1, "Wrong protocolFees1");
        assertEq(airlock.getIntegratorFees(DEFAULT_INTEGRATOR, token0), integratorFees0, "Wrong integratorFees0");
        assertEq(airlock.getIntegratorFees(DEFAULT_INTEGRATOR, token1), integratorFees1, "Wrong integratorFees1");
    }

    function _migrate(
        address token0,
        uint128 fees0,
        uint128 balance0,
        address token1,
        uint128 fees1,
        uint128 balance1
    ) internal {
        uint160 sqrtPriceX96 = uint160(2 ** 96);

        address asset = makeAddr("Asset");
        address timelock = makeAddr("Timelock");
        address poolInitializer = makeAddr("PoolInitializer");
        address pool = makeAddr("Pool");
        address liquidityMigrator = makeAddr("LiquidityMigrator");
        address migrationPool = makeAddr("MigrationPool");

        AssetData memory assetData = AssetData({
            numeraire: address(0),
            timelock: timelock,
            governance: address(0),
            liquidityMigrator: ILiquidityMigrator(liquidityMigrator),
            poolInitializer: IPoolInitializer(poolInitializer),
            pool: pool,
            migrationPool: migrationPool,
            numTokensToSell: 0,
            totalSupply: 0,
            integrator: DEFAULT_INTEGRATOR
        });

        airlock.setAssetData(asset, assetData);

        vm.expectCall(asset, abi.encodeWithSelector(DERC20.unlockPool.selector));
        vm.expectCall(asset, abi.encodeWithSelector(Ownable.transferOwnership.selector, timelock));
        vm.expectCall(
            liquidityMigrator,
            abi.encodeWithSelector(ILiquidityMigrator.migrate.selector, sqrtPriceX96, token0, token1, timelock)
        );

        vm.mockCall(asset, abi.encodeWithSelector(DERC20.unlockPool.selector), new bytes(0));
        vm.mockCall(asset, abi.encodeWithSelector(Ownable.transferOwnership.selector, timelock), new bytes(0));
        vm.mockCall(
            poolInitializer,
            abi.encodeWithSelector(IPoolInitializer.exitLiquidity.selector, pool),
            abi.encode(sqrtPriceX96, token0, fees0, balance0, token1, fees1, balance1)
        );
        vm.mockCall(
            token0, abi.encodeWithSelector(ERC20.transfer.selector, liquidityMigrator, balance0 - fees0), new bytes(0)
        );
        vm.mockCall(
            token1, abi.encodeWithSelector(ERC20.transfer.selector, liquidityMigrator, balance1 - fees1), new bytes(0)
        );

        // TODO: I wanted to use mockCall here but for some reason it doesn't work
        // vm.mockCall(liquidityMigrator, abi.encodeWithSelector(ILiquidityMigrator.migrate.selector, sqrtPriceX96, token0, token1, timelock), new bytes(0));
        MockLiquidityMigrator lm = new MockLiquidityMigrator();
        vm.etch(liquidityMigrator, address(lm).code);

        vm.expectEmit();
        emit Migrate(asset, migrationPool);
        airlock.migrate(asset);
    }

    function test_create_RevertsIfWrongTokenFactory() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongModuleState.selector, address(0xdead), ModuleState.TokenFactory, ModuleState.NotWhitelisted
            )
        );
        airlock.create(
            CreateParams(
                DEFAULT_INITIAL_SUPPLY,
                DEFAULT_INITIAL_SUPPLY,
                WETH_MAINNET,
                ITokenFactory(address(0xdead)),
                new bytes(0),
                governanceFactory,
                new bytes(0),
                uniswapV3Initializer,
                new bytes(0),
                uniswapV2LiquidityMigrator,
                new bytes(0),
                address(0xb0b),
                bytes32(uint256(0xbeef))
            )
        );
    }

    function test_create_RevertsIfWrongGovernanceFactory() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongModuleState.selector, address(0xdead), ModuleState.GovernanceFactory, ModuleState.NotWhitelisted
            )
        );
        airlock.create(
            CreateParams(
                DEFAULT_INITIAL_SUPPLY,
                DEFAULT_INITIAL_SUPPLY,
                WETH_MAINNET,
                tokenFactory,
                new bytes(0),
                IGovernanceFactory(address(0xdead)),
                new bytes(0),
                uniswapV3Initializer,
                new bytes(0),
                uniswapV2LiquidityMigrator,
                new bytes(0),
                address(0xb0b),
                bytes32(uint256(0xbeef))
            )
        );
    }

    function test_create_RevertsIfWrongPoolInitializer() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongModuleState.selector, address(0xdead), ModuleState.PoolInitializer, ModuleState.NotWhitelisted
            )
        );
        airlock.create(
            CreateParams(
                DEFAULT_INITIAL_SUPPLY,
                DEFAULT_INITIAL_SUPPLY,
                WETH_MAINNET,
                tokenFactory,
                new bytes(0),
                governanceFactory,
                new bytes(0),
                IPoolInitializer(address(0xdead)),
                new bytes(0),
                uniswapV2LiquidityMigrator,
                new bytes(0),
                address(0xb0b),
                bytes32(uint256(0xbeef))
            )
        );
    }

    function test_create_RevertsIfWrongLiquidityMigrator() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WrongModuleState.selector, address(0xdead), ModuleState.LiquidityMigrator, ModuleState.NotWhitelisted
            )
        );
        airlock.create(
            CreateParams(
                DEFAULT_INITIAL_SUPPLY,
                DEFAULT_INITIAL_SUPPLY,
                WETH_MAINNET,
                tokenFactory,
                new bytes(0),
                governanceFactory,
                new bytes(0),
                uniswapV3Initializer,
                new bytes(0),
                ILiquidityMigrator(address(0xdead)),
                new bytes(0),
                address(0xb0b),
                bytes32(uint256(0xbeef))
            )
        );
    }

    // TODO: It would be better to move this into an integration test
    function test_create_DeploysOnUniswapV3() public {
        bytes memory tokenFactoryData =
            abi.encode(DEFAULT_TOKEN_NAME, DEFAULT_TOKEN_SYMBOL, 0, 0, new address[](0), new uint256[](0), "");
        bytes memory governanceFactoryData = abi.encode(DEFAULT_TOKEN_NAME, 7200, 50_400, 0);
        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: uint24(3000),
                tickLower: DEFAULT_START_TICK,
                tickUpper: DEFAULT_END_TICK,
                numPositions: 1,
                maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD
            })
        );

        airlock.create(
            CreateParams(
                DEFAULT_INITIAL_SUPPLY,
                DEFAULT_INITIAL_SUPPLY,
                WETH_MAINNET,
                tokenFactory,
                tokenFactoryData,
                governanceFactory,
                governanceFactoryData,
                uniswapV3Initializer,
                poolInitializerData,
                uniswapV2LiquidityMigrator,
                new bytes(0),
                address(0xb0b),
                bytes32(uint256(0xbeef))
            )
        );
    }

    function test_collectProtocolFees_RevertsWhenCallerNotOwner() public {
        vm.startPrank(address(0xb0b));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xb0b)));
        airlock.collectProtocolFees(address(0), address(0), 0);
    }

    function test_collectProtocolFees_CollectsFees() public {
        TestERC20 token = new TestERC20(1 ether);
        token.transfer(address(airlock), 1 ether);
        airlock.setProtocolFees(address(token), 1 ether);
        vm.expectEmit();
        emit Collect(address(this), address(token), 1 ether);
        airlock.collectProtocolFees(address(this), address(token), 1 ether);
        assertEq(token.balanceOf(address(this)), 1 ether, "Owner balance is wrong");
        assertEq(token.balanceOf(address(airlock)), 0, "Airlock balance is wrong");
    }

    function test_collectIntegratorFees_CollectFees() public {
        TestERC20 token = new TestERC20(1 ether);
        token.transfer(address(airlock), 1 ether);
        airlock.setIntegratorFees(address(this), address(token), 1 ether);
        vm.expectEmit();
        emit Collect(address(this), address(token), 1 ether);
        airlock.collectIntegratorFees(address(this), address(token), 1 ether);
        assertEq(token.balanceOf(address(this)), 1 ether, "Integrator balance is wrong");
        assertEq(token.balanceOf(address(airlock)), 0, "Airlock balance is wrong");
    }

    function test_collectIntegratorFees_RevertsWhenAmountIsGreaterThanAvailableFees() public {
        TestERC20 token = new TestERC20(1 ether);
        token.transfer(address(airlock), 1 ether);
        airlock.setIntegratorFees(address(this), address(token), 1 ether);
        vm.expectRevert(stdError.arithmeticError);
        airlock.collectIntegratorFees(address(this), address(token), 1 ether + 1);
    }
}
