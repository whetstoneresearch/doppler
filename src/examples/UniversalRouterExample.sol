// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { Commands } from "@universal-router/libraries/Commands.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IV4Router } from "@v4-periphery/interfaces/IV4Router.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";

contract UniversalRouterExample {
    using StateLibrary for IPoolManager;

    UniversalRouter public immutable router;
    IPoolManager public immutable poolManager;
    IPermit2 public immutable permit2;

    constructor(address _router, address _poolManager, address _permit2) {
        router = UniversalRouter(payable(_router));
        poolManager = IPoolManager(_poolManager);
        permit2 = IPermit2(_permit2);
    }

    // Additional functionality will be added as v4 swap support evolves
}
