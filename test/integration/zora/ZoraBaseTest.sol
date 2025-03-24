// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import { OwnableUpgradeable } from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Address } from "@openzeppelin/utils/Address.sol";
import { ERC1967Utils } from "@openzeppelin/proxy/ERC1967/ERC1967Utils.sol";
import { IERC165 } from "@openzeppelin/utils/introspection/IERC165.sol";
import { IERC20Metadata } from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import { ZoraTokenFactoryImpl } from "../../../src/zora/ZoraTokenFactoryImpl.sol";
import { ZoraFactory } from "@zora-protocol/coins/src/proxy/ZoraFactory.sol";
import { ZoraCoin } from "src/zora/ZoraCoin.sol";
import { CoinConstants } from "@zora-protocol/coins/src/utils/CoinConstants.sol";
import { MultiOwnable } from "@zora-protocol/coins/src/utils/MultiOwnable.sol";
import { ICoin } from "@zora-protocol/coins/src/interfaces/ICoin.sol";
import { IERC7572 } from "@zora-protocol/coins/src/interfaces/IERC7572.sol";
import { IWETH } from "@zora-protocol/coins/src/interfaces/IWETH.sol";
import { INonfungiblePositionManager } from "@zora-protocol/coins/src/interfaces/INonfungiblePositionManager.sol";
import { ISwapRouter } from "@zora-protocol/coins/src/interfaces/ISwapRouter.sol";
import { IUniswapV3Pool } from "@zora-protocol/coins/src/interfaces/IUniswapV3Pool.sol";
import { IProtocolRewards } from "@zora-protocol/coins/src/interfaces/IProtocolRewards.sol";
import { ProtocolRewards } from "@zora-protocol/coins/test/utils/ProtocolRewards.sol";

import { UniswapV3Initializer, InitData } from "src/UniswapV3Initializer.sol";
import { Airlock, ModuleState, CreateParams, ITokenFactory, IGovernanceFactory } from "src/Airlock.sol";
import { UniswapV2Migrator } from "src/UniswapV2Migrator.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { GovernanceFactory } from "src/GovernanceFactory.sol";

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { UniswapV2Migrator, IUniswapV2Router02, IUniswapV2Factory, IUniswapV2Pair } from "src/UniswapV2Migrator.sol";
import { ZoraUniswapV3Migrator } from "src/zora/ZoraUniswapV3Migrator.sol";

int24 constant DEFAULT_LOWER_TICK = 167_600;
int24 constant DEFAULT_UPPER_TICK = 200_000;
int24 constant DEFAULT_TARGET_TICK = DEFAULT_UPPER_TICK - 16_000;
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.23 ether;

function adjustTick(int24 tick, int24 tickSpacing) pure returns (int24) {
    return tick - (tick % tickSpacing);
}

contract ZoraBaseTest is Test, CoinConstants {
    using stdStorage for StdStorage;

    address internal constant PROTOCOL_REWARDS = 0x7777777F279eba3d3Ad8F4E708545291A6fDBA8B;
    address internal constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006;
    address internal constant NONFUNGIBLE_POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address internal constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    int24 internal constant USDC_TICK_LOWER = 57_200;

    address internal constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant UNISWAP_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address internal constant UNISWAP_V2_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;

    struct Users {
        address factoryOwner;
        address feeRecipient;
        address creator;
        address platformReferrer;
        address buyer;
        address seller;
        address coinRecipient;
        address tradeReferrer;
    }

    uint256 internal forkId;
    IERC20Metadata internal usdc;
    IWETH internal weth;
    ProtocolRewards internal protocolRewards;
    INonfungiblePositionManager internal nonfungiblePositionManager;
    ISwapRouter internal swapRouter;
    Users internal users;

    ZoraCoin internal coinImpl;
    ZoraCoin internal coin;
    IUniswapV3Pool internal pool;
    address public asset;

    UniswapV3Initializer public initializer;
    Airlock public airlock;
    UniswapV2Migrator public uniswapV2LiquidityMigrator;
    ZoraTokenFactoryImpl public tokenFactoryImpl;
    ZoraTokenFactoryImpl public tokenFactory;
    GovernanceFactory public governanceFactory;
    ZoraUniswapV3Migrator public uniswapV3Migrator;

    function setUp() public virtual {
        forkId = vm.createSelectFork(vm.envString("BASE_RPC_URL"), 21_179_722);

        weth = IWETH(WETH_ADDRESS);
        usdc = IERC20Metadata(USDC_ADDRESS);
        nonfungiblePositionManager = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER);
        swapRouter = ISwapRouter(SWAP_ROUTER);
        protocolRewards = new ProtocolRewards();

        users = Users({
            factoryOwner: makeAddr("factoryOwner"),
            feeRecipient: makeAddr("feeRecipient"),
            creator: makeAddr("creator"),
            platformReferrer: makeAddr("platformReferrer"),
            buyer: makeAddr("buyer"),
            seller: makeAddr("seller"),
            coinRecipient: makeAddr("coinRecipient"),
            tradeReferrer: makeAddr("tradeReferrer")
        });

        airlock = new Airlock(address(this));

        coinImpl = new ZoraCoin(
            users.feeRecipient,
            address(protocolRewards),
            WETH_ADDRESS,
            NONFUNGIBLE_POSITION_MANAGER,
            SWAP_ROUTER,
            UNISWAP_V3_FACTORY,
            address(airlock)
        );

        initializer = new UniswapV3Initializer(address(airlock), IUniswapV3Factory(UNISWAP_V3_FACTORY));
        uniswapV3Migrator = new ZoraUniswapV3Migrator(address(airlock), address(UNISWAP_V3_FACTORY));
        tokenFactoryImpl = new ZoraTokenFactoryImpl(address(coinImpl), address(airlock));
        tokenFactory = ZoraTokenFactoryImpl(address(new ZoraFactory(address(tokenFactoryImpl))));
        tokenFactory.initialize(users.factoryOwner);
        governanceFactory = new GovernanceFactory(address(airlock));

        // ZoraTokenFactoryImpl(factory).initialize(users.factoryOwner);

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(uniswapV3Migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;
        airlock.setModuleState(modules, states);

        vm.label(address(tokenFactory), "ZORA_FACTORY");
        vm.label(address(protocolRewards), "PROTOCOL_REWARDS");
        vm.label(address(nonfungiblePositionManager), "NONFUNGIBLE_POSITION_MANAGER");
        vm.label(address(swapRouter), "SWAP_ROUTER");
        vm.label(address(weth), "WETH");
        vm.label(address(usdc), "USDC");
    }

    function test_ZoraTokenFactoryImpl_constructor() public { }

    function test_ZoraTokenFactoryImpl_create() public {
        uint256 initialSupply = 100_000_000 ether;
        uint24 fee = 10_000;
        address payoutRecipient = address(0xb055);
        string memory uri = "test.com";
        string memory name = "Best Coin";
        string memory symbol = "BEST";
        address platformReferrer = address(0xb055);
        address currency = address(weth);

        address predictedAddress = tokenFactory.getCoinAddress(address(airlock), payoutRecipient, uri);

        bytes memory governanceData = abi.encode(name, 7200, 50_400, 0);
        bytes memory tokenFactoryData =
            abi.encode(payoutRecipient, uri, name, symbol, platformReferrer, currency, predictedAddress);
        bytes memory liquidityMigratorData = abi.encode(fee, NONFUNGIBLE_POSITION_MANAGER);

        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: fee,
                tickLower: DEFAULT_LOWER_TICK,
                tickUpper: DEFAULT_UPPER_TICK,
                numPositions: 10,
                maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD
            })
        );

        (address _asset, address _pool,,,) = airlock.create(
            CreateParams(
                initialSupply,
                initialSupply,
                WETH_ADDRESS,
                ITokenFactory(address(tokenFactory)),
                tokenFactoryData,
                IGovernanceFactory(governanceFactory),
                governanceData,
                initializer,
                poolInitializerData,
                uniswapV3Migrator,
                liquidityMigratorData,
                address(predictedAddress),
                bytes32(0)
            )
        );

        pool = IUniswapV3Pool(_pool);
        asset = _asset;

        assertNotEq(address(pool), address(0));
        assertNotEq(address(asset), address(0));

        assertEq(address(pool), IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(address(weth), address(asset), fee));
    }

    function test_ZoraTokenFactoryImpl_buy_NoMigrate() public {
        initializePool();

        ZoraCoin(payable(asset)).approve(address(asset), type(uint256).max);
        ZoraCoin(payable(asset)).buy{ value: 0.01 ether }(address(this), 0.01 ether, 0, 0, address(users.tradeReferrer));
    }

    function test_ZoraTokenFactoryImpl_sell_NoMigrate() public {
        initializePool();

        uint256 balanceCoinBefore = ZoraCoin(payable(asset)).balanceOf(address(this));

        ZoraCoin(payable(asset)).approve(address(asset), type(uint256).max);
        ZoraCoin(payable(asset)).buy{ value: 0.01 ether }(address(this), 0.01 ether, 0, 0, address(users.tradeReferrer));

        uint256 balanceCoinAfter = ZoraCoin(payable(asset)).balanceOf(address(this));

        assertGt(balanceCoinAfter, balanceCoinBefore);

        ZoraCoin(payable(asset)).sell(
            address(this), balanceCoinAfter - balanceCoinBefore, 0, 0, address(users.tradeReferrer)
        );
    }

    function test_ZoraTokenFactoryImpl_buyAndMigrate() public {
        initializePool();

        ZoraCoin(payable(asset)).approve(address(asset), type(uint256).max);
        ZoraCoin(payable(asset)).buy{ value: 10 ether }(address(this), 10 ether, 0, 0, address(users.tradeReferrer));
    }

    function test_ZoraTokenFactoryImpl_buy_CollectsRewardsPostMigration() public {
        initializePool();

        ZoraCoin(payable(asset)).approve(address(asset), type(uint256).max);
        ZoraCoin(payable(asset)).buy{ value: 10 ether }(address(this), 10 ether, 0, 0, address(users.tradeReferrer));

        vm.warp(block.timestamp + 1000);
        ZoraCoin(payable(asset)).buy{ value: 0.1 ether }(address(this), 0.1 ether, 0, 0, address(users.tradeReferrer));
    }

    function test_ZoraTokenFactoryImpl_sell_CollectsRewardsPostMigration() public {
        initializePool();

        uint256 balanceCoinBefore = ZoraCoin(payable(asset)).balanceOf(address(this));

        // migrate the pool
        ZoraCoin(payable(asset)).approve(address(asset), type(uint256).max);
        ZoraCoin(payable(asset)).buy{ value: 10 ether }(address(this), 10 ether, 0, 0, address(users.tradeReferrer));

        uint256 balanceCoinAfter = ZoraCoin(payable(asset)).balanceOf(address(this));

        assertGt(balanceCoinAfter, balanceCoinBefore);

        uint256 balanceEthBefore = address(this).balance;

        vm.warp(block.timestamp + 1000);
        ZoraCoin(payable(asset)).sell(
            address(this), balanceCoinAfter - balanceCoinBefore, 0, 0, address(users.tradeReferrer)
        );

        uint256 balanceEthAfter = address(this).balance;
        assertGt(balanceEthAfter, balanceEthBefore);
    }

    receive() external payable { }

    struct TradeRewards {
        uint256 creator;
        uint256 platformReferrer;
        uint256 tradeReferrer;
        uint256 protocol;
    }

    struct MarketRewards {
        uint256 creator;
        uint256 platformReferrer;
        uint256 protocol;
    }

    function _deployCoin() internal {
        address[] memory owners = new address[](1);
        owners[0] = users.creator;

        vm.prank(users.creator);
        (address coinAddress,) = tokenFactory.deploy(
            users.creator,
            owners,
            "https://test.com",
            "Testcoin",
            "TEST",
            users.platformReferrer,
            address(weth),
            LP_TICK_LOWER_WETH,
            0
        );

        coin = ZoraCoin(payable(coinAddress));
        pool = IUniswapV3Pool(coin.poolAddress());

        vm.label(address(coin), "COIN");
        vm.label(address(pool), "POOL");
    }

    function _deployCoinUSDCPair() internal {
        address[] memory owners = new address[](1);
        owners[0] = users.creator;

        vm.prank(users.creator);
        (address coinAddress,) = tokenFactory.deploy(
            users.creator,
            owners,
            "https://testusdccoin.com",
            "Testusdccoin",
            "TESTUSDCCOIN",
            users.platformReferrer,
            USDC_ADDRESS,
            USDC_TICK_LOWER,
            0
        );

        coin = ZoraCoin(payable(coinAddress));
        pool = IUniswapV3Pool(coin.poolAddress());

        vm.label(address(coin), "COIN");
        vm.label(address(pool), "POOL");
    }

    function _calculateTradeRewards(
        uint256 ethAmount
    ) internal pure returns (TradeRewards memory) {
        return TradeRewards({
            creator: (ethAmount * 5000) / 10_000,
            platformReferrer: (ethAmount * 1500) / 10_000,
            tradeReferrer: (ethAmount * 1500) / 10_000,
            protocol: (ethAmount * 2000) / 10_000
        });
    }

    function _calculateExpectedFee(
        uint256 ethAmount
    ) internal pure returns (uint256) {
        uint256 feeBps = 100; // 1%
        return (ethAmount * feeBps) / 10_000;
    }

    function _calculateMarketRewards(
        uint256 ethAmount
    ) internal pure returns (MarketRewards memory) {
        uint256 creator = (ethAmount * 5000) / 10_000;
        uint256 platformReferrer = (ethAmount * 2500) / 10_000;
        uint256 protocol = ethAmount - creator - platformReferrer;

        return MarketRewards({ creator: creator, platformReferrer: platformReferrer, protocol: protocol });
    }

    function dealUSDC(address to, uint256 numUSDC) internal returns (uint256) {
        uint256 amount = numUSDC * 1e6;
        deal(address(usdc), to, amount);
        return amount;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external { }

    function initializePool() internal {
        uint256 initialSupply = 100_000_000 ether;
        uint24 fee = 10_000;
        address payoutRecipient = address(0xb055);
        string memory uri = "test.com";
        string memory name = "Best Coin";
        string memory symbol = "BEST";
        address platformReferrer = address(0xbadd);
        address currency = address(weth);

        address predictedAddress = tokenFactory.getCoinAddress(address(airlock), payoutRecipient, uri);
        bytes memory governanceData = abi.encode(name, 7200, 50_400, 0);
        bytes memory tokenFactoryData =
            abi.encode(payoutRecipient, uri, name, symbol, platformReferrer, currency, predictedAddress);
        bytes memory liquidityMigratorData = abi.encode(fee, NONFUNGIBLE_POSITION_MANAGER);

        bytes memory poolInitializerData = abi.encode(
            InitData({
                fee: fee,
                tickLower: DEFAULT_LOWER_TICK,
                tickUpper: DEFAULT_UPPER_TICK,
                numPositions: 10,
                maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD
            })
        );

        (address _asset, address _pool,,,) = airlock.create(
            CreateParams(
                initialSupply,
                initialSupply,
                WETH_ADDRESS,
                ITokenFactory(address(tokenFactory)),
                tokenFactoryData,
                IGovernanceFactory(governanceFactory),
                governanceData,
                initializer,
                poolInitializerData,
                uniswapV3Migrator,
                liquidityMigratorData,
                address(tokenFactory),
                bytes32(0)
            )
        );

        pool = IUniswapV3Pool(_pool);
        asset = _asset;

        deal(address(this), 100_000_000 ether);
        weth.deposit{ value: 1_000_000 ether }();
        weth.approve(address(asset), type(uint256).max);
    }
}
