/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test } from "forge-std/Test.sol";
import { Create2 } from "@openzeppelin/utils/Create2.sol";
import { Commands } from "@universal-router/libraries/Commands.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { DERC20 } from "src/DERC20.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { InitData } from "src/UniswapV3Initializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { CreateParams } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";

contract BundlerTest is Test {
    Bundler bundler;

    receive() external payable { }

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_MAINNET_RPC_URL"), 10_594_210);
        bundler = new Bundler(
            payable(0x77EbfBAE15AD200758E9E2E61597c0B07d731254),
            payable(0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3),
            0x385A5cf5F83e99f7BB2852b6A19C3538b9FA7658
        );
    }

    function test_bundle() public {
        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 initialSupply = 1e30;

        CreateParams memory createParams = CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: address(0x4200000000000000000000000000000000000006),
            tokenFactory: ITokenFactory(0x43d0D97EC9241A8F05A264f94B82A1d2E600f2B3),
            tokenFactoryData: abi.encode(name, symbol, 0, 0, new address[](0), new uint256[](0), ""),
            governanceFactory: IGovernanceFactory(0x99C94B9Df930E1E21a4E4a2c105dBff21bF5c5aE),
            governanceFactoryData: abi.encode("Governance", 3, 3, 3),
            poolInitializer: IPoolInitializer(0x9F4e56be80f08ba1A2445645EFa6d231E27b43ec),
            poolInitializerData: abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: -200_040,
                    tickUpper: -167_520,
                    numPositions: 10,
                    maxShareToBeSold: 0.23 ether
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
                        name,
                        symbol,
                        initialSupply,
                        0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
                        0x77EbfBAE15AD200758E9E2E61597c0B07d731254,
                        0,
                        0,
                        new address[](0),
                        new uint256[](0),
                        ""
                    )
                )
            ),
            0x43d0D97EC9241A8F05A264f94B82A1d2E600f2B3
        );

        uint256 amountIn = 1 ether;

        bytes memory commands = abi.encodePacked(uint8(Commands.WRAP_ETH), uint8(Commands.V3_SWAP_EXACT_IN));

        address tokenIn = 0x4200000000000000000000000000000000000006;
        address tokenOut = asset;
        bytes memory path = abi.encodePacked(tokenIn, uint24(3000), tokenOut);

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3, amountIn);
        inputs[1] = abi.encode(address(this), amountIn, uint256(0), path, false);

        vm.deal(address(this), amountIn);

        bundler.bundle{ value: amountIn }(createParams, commands, inputs);

        assertEq(address(this).balance, 0, "Wrong ETH balance");
        assertGt(DERC20(asset).balanceOf(address(this)), 0, "Wrong asset balance");
    }
}
