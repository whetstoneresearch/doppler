// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ChainIds } from "script/ChainIds.sol";
import { DeployScript, ScriptData } from "script/deploy/Deploy.s.sol";

contract DeployBaseSepolia is DeployScript {
    function setUp() public override {
        _scriptData = ScriptData({
            chainId: ChainIds.BASE_SEPOLIA,
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            protocolOwner: 0xaCE07c3c1D3b556D42633211f0Da71dc6F6d1c42,
            quoterV2: 0xC5290058841028F1614F3A6F0F5816cAd0df5E27,
            uniswapV2Factory: 0x7Ae58f10f7849cA6F5fB71b7f45CB416c9204b1e,
            uniswapV2Router02: 0x1689E7B1F10000AE47eBfE339a4f69dECd19F602,
            uniswapV3Factory: 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24,
            universalRouter: 0x492E6456D9528771018DeB9E87ef7750EF184104,
            stateView: 0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4,
            positionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80
        });
    }
}
