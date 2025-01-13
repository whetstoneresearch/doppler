/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import { Doppler } from "src/Doppler.sol";

interface IDopplerDeployer {
    function deploy(uint256 numTokensToSell, bytes32 salt, bytes calldata data) external returns (Doppler);
}
