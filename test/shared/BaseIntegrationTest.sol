// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { Deploy } from "@v4-periphery-test/shared/Deploy.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";
import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Airlock } from "src/Airlock.sol";

abstract contract BaseIntegrationTest is Deployers, DeployPermit2 {
    address internal AIRLOCK_OWNER = makeAddr("AIRLOCK_OWNER");

    IAllowanceTransfer public permit2;
    Airlock public airlock;
    IPositionManager public positionManager;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager = Deploy.positionManager(
            address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
        );
        airlock = new Airlock(AIRLOCK_OWNER);
    }
}
