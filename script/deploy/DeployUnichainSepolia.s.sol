// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployScript, ScriptData } from "script/deploy/Deploy.s.sol";

contract DeployUnichainSepolia is DeployScript {
    function setUp() public override {
        _scriptData = ScriptData({
            deployBundler: true,
            deployLens: true,
            explorerUrl: "https://unichain-sepolia.blockscout.com/address/",
            poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
            protocolOwner: 0xaCE07c3c1D3b556D42633211f0Da71dc6F6d1c42,
            quoterV2: 0xbc02cBE6e4E29B504b67b0187A0178E13871fA3C,
            uniswapV2Factory: 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f,
            uniswapV2Router02: 0x920b806E40A00E02E7D2b94fFc89860fDaEd3640,
            uniswapV3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            universalRouter: 0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D,
            stateView: 0xc199F1072a74D4e905ABa1A84d9a45E2546B6222,
            positionManager: 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664
        });
    }
}
