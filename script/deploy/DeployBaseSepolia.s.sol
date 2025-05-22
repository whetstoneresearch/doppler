// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { DeployScript, ScriptData } from "script/deploy/Deploy.s.sol";

contract DeployBaseSepolia is DeployScript {
    function setUp() public override {
        _scriptData = ScriptData({
            deployBundler: true,
            deployLens: true,
            explorerUrl: "https://base-sepolia.blockscout.com/address/",
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            protocolOwner: 0x21E2ce70511e4FE542a97708e89520471DAa7A66,
            quoterV2: 0xC5290058841028F1614F3A6F0F5816cAd0df5E27,
            uniswapV2Factory: 0x7Ae58f10f7849cA6F5fB71b7f45CB416c9204b1e,
            uniswapV2Router02: 0x1689E7B1F10000AE47eBfE339a4f69dECd19F602,
            uniswapV3Factory: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24,
            universalRouter: 0x492E6456D9528771018DeB9E87ef7750EF184104,
            stateView: 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4
        });
    }
}
