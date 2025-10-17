// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {
    BaseIntegrationTest,
    deployTokenFactory,
    deployNoOpMigrator,
    deployNoOpGovernanceFactory
} from "test/integration/BaseIntegrationTest.sol";
import { TokenFactory } from "src/TokenFactory.sol";
import { NoOpGovernanceFactory } from "src/NoOpGovernanceFactory.sol";
import { NoOpMigrator } from "src/NoOpMigrator.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/UniswapV4Initializer.sol";
import { deployUniswapV4Initializer, preparePoolInitializerData } from "test/integration/UniswapV4Initializer.t.sol";

contract TokenFactoryUniswapV4InitializerNoOpMigratorNoOpGovernanceFactory is BaseIntegrationTest {
    function setUp() public override {
        super.setUp();

        name = "TokenFactory + UniswapV4Initializer + NoOpMigrator + NoOpGovernanceFactory";

        TokenFactory tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData =
            abi.encode("Test Token", "TEST", 0, 0, new address[](0), new uint256[](0), "TOKEN_URI");

        (, UniswapV4Initializer initializer) = deployUniswapV4Initializer(vm, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        (bytes32 salt, bytes memory poolInitializerData) = preparePoolInitializerData(
            address(airlock),
            address(manager),
            address(tokenFactory),
            createParams.tokenFactoryData,
            address(initializer)
        );
        createParams.poolInitializerData = poolInitializerData;
        createParams.salt = salt;
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;

        shouldSkipMigrate = true;
    }
}
