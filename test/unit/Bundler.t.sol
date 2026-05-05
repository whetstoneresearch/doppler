/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Create2 } from "@openzeppelin/utils/Create2.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { Commands } from "@universal-router/libraries/Commands.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { IV4Quoter } from "@v4-periphery/interfaces/IV4Quoter.sol";
import { Test } from "forge-std/Test.sol";
import { Airlock, ModuleState } from "src/Airlock.sol";
import { CreateParams } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";
import { InitData } from "src/initializers/UniswapV3Initializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { DERC20 } from "src/tokens/DERC20.sol";
import { ITokenFactory, TokenFactory } from "src/tokens/TokenFactory.sol";

address payable constant airlock = payable(0x77EbfBAE15AD200758E9E2E61597c0B07d731254);
address payable constant ur = payable(0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3);
address constant quoterV2 = 0x385A5cf5F83e99f7BB2852b6A19C3538b9FA7658;
address constant WETH = 0x4200000000000000000000000000000000000006;

contract BundlerTest is Test {
    Bundler bundler;
    TokenFactory tokenFactory;
    DummyV4Quoter dummyV4Quoter;

    receive() external payable { }

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_MAINNET_RPC_URL"), 10_594_210);
        dummyV4Quoter = new DummyV4Quoter();
        bundler =
            new Bundler(Airlock(airlock), UniversalRouter(ur), IQuoterV2(quoterV2), IV4Quoter(address(dummyV4Quoter)));

        tokenFactory = new TokenFactory(airlock);
        vm.prank(Airlock(airlock).owner());

        address[] memory modules = new address[](1);
        modules[0] = address(tokenFactory);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.TokenFactory;
        Airlock(airlock).setModuleState(modules, states);
    }

    function test_bundle() public {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e30;

        CreateParams memory createParams = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: WETH,
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), ""),
            governanceFactory: IGovernanceFactory(0x99C94B9Df930E1E21a4E4a2c105dBff21bF5c5aE),
            governanceFactoryData: abi.encode("Governance", 3, 3, 3),
            poolInitializer: IPoolInitializer(0x9F4e56be80f08ba1A2445645EFa6d231E27b43ec),
            poolInitializerData: abi.encode(
                InitData({
                    fee: 3000, tickLower: -200_040, tickUpper: -167_520, numPositions: 10, maxShareToBeSold: 0.23 ether
                })
            ),
            liquidityMigrator: ILiquidityMigrator(0xf6023127f6E937091D5B605680056A6D27524bad),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: bytes32(uint256(0xbeef))
        });

        address asset = Create2.computeAddress(
            createParams.salt,
            keccak256(
                abi.encodePacked(
                    type(DERC20).creationCode,
                    abi.encode(
                        name, symbol, initialSupply, airlock, airlock, 0, 0, new address[](0), new uint256[](0), ""
                    )
                )
            ),
            address(tokenFactory)
        );

        uint256 amountIn = 1 ether;

        bytes memory commands = abi.encodePacked(uint8(Commands.WRAP_ETH), uint8(Commands.V3_SWAP_EXACT_IN));

        address tokenIn = 0x4200000000000000000000000000000000000006;
        address tokenOut = asset;
        bytes memory path = abi.encodePacked(tokenIn, uint24(3000), tokenOut);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ur, amountIn);
        inputs[1] = abi.encode(address(this), amountIn, uint256(0), path, false);

        vm.deal(address(this), amountIn);

        bundler.bundle{ value: amountIn }(createParams, commands, inputs);

        assertEq(address(this).balance, 0, "Wrong ETH balance");
        assertGt(DERC20(asset).balanceOf(address(this)), 0, "Wrong asset balance");
    }
}

contract DummyV4Quoter {
    function quoteExactOutputSingle(IV4Quoter.QuoteExactSingleParams memory)
        external
        pure
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        return (0, 0);
    }

    function quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams memory)
        external
        pure
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        return (0, 0);
    }
}
