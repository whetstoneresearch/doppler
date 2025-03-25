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
import { ZoraBaseTest } from "./ZoraBaseTest.sol";

int24 constant DEFAULT_LOWER_TICK = 167_600;
int24 constant DEFAULT_UPPER_TICK = 200_000;
int24 constant DEFAULT_TARGET_TICK = DEFAULT_UPPER_TICK - 16_000;
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.23 ether;

function adjustTick(int24 tick, int24 tickSpacing) pure returns (int24) {
    return tick - (tick % tickSpacing);
}

contract ZoraCoins is ZoraBaseTest {
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

    function test_ZoraTokenTradeRewards_onBuyPreMigration() public {
        initializePool();

        uint256 creatorRewardsBefore = protocolRewards.balanceOf(users.creator);
        uint256 platformReferrerRewardsBefore = protocolRewards.balanceOf(users.platformReferrer);
        uint256 tradeReferrerRewardsBefore = protocolRewards.balanceOf(users.tradeReferrer);
        uint256 protocolRewardsBefore = protocolRewards.balanceOf(PROTOCOL_REWARDS);

        console.log("creatorRewardsBefore", creatorRewardsBefore);
        console.log("platformReferrerRewardsBefore", platformReferrerRewardsBefore);
        console.log("tradeReferrerRewardsBefore", tradeReferrerRewardsBefore);
        console.log("protocolRewardsBefore", protocolRewardsBefore);

        (uint256 orderSize,) = ZoraCoin(payable(asset)).buy{ value: 0.01 ether }(
            address(this), 0.01 ether, 0, 0, address(users.tradeReferrer)
        );

        TradeRewards memory rewards = _calculateTradeRewards(0.01 ether);

        // uint256 trueOrderSize = orderSize * TOTAL_FEE_BPS / 10_000;
        // compute the amount taken as fee by uniswap
        // MarketRewards memory marketRewards = _calculateMarketRewards(expectedFee);

        console.log("rewards.creator", rewards.creator);
        // console.log("marketRewards.creator", marketRewards.creator);

        assertGt(protocolRewards.balanceOf(users.creator), creatorRewardsBefore);
        assertGt(protocolRewards.balanceOf(users.platformReferrer), platformReferrerRewardsBefore);
        assertGt(protocolRewards.balanceOf(users.tradeReferrer), tradeReferrerRewardsBefore);
        assertGt(protocolRewards.balanceOf(PROTOCOL_REWARDS), protocolRewardsBefore);

        // TODO: assert that the rewards are correct
        // assertEq(
        //     protocolRewards.balanceOf(users.creator),
        //     creatorRewardsBefore + rewards.creator + marketRewards.creator,
        //     "Creator rewards not correct"
        // );
        // assertEq(
        //     protocolRewards.balanceOf(users.platformReferrer),
        //     platformReferrerRewardsBefore + rewards.platformReferrer + marketRewards.platformReferrer,
        //     "Platform referrer rewards not correct"
        // );
        // assertEq(
        //     protocolRewards.balanceOf(users.tradeReferrer),
        //     tradeReferrerRewardsBefore + rewards.tradeReferrer,
        //     "Trade referrer rewards not correct"
        // );
        // assertEq(
        //     protocolRewards.balanceOf(PROTOCOL_REWARDS),
        //     protocolRewardsBefore + rewards.protocol + marketRewards.protocol,
        //     "Protocol rewards not correct"
        // );
    }
}
