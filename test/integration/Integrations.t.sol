// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { ModuleState } from "src/Airlock.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInitializer } from "src/initializers/DopplerHookInitializer.sol";
import {
    InitData as LockableUniswapV3InitData,
    LockableUniswapV3Initializer
} from "src/initializers/LockableUniswapV3Initializer.sol";
import { UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import {
    BaseIntegrationTest,
    deployNoOpGovernanceFactory,
    deployNoOpMigrator,
    deployTokenFactory,
    prepareTokenFactoryData
} from "test/integration/BaseIntegrationTest.sol";
import {
    deployDopplerHookMulticurveInitializer,
    prepareDopplerHookMulticurveInitializerData
} from "test/integration/DopplerHookInitializer.t.sol";
import { deployUniswapV4Initializer, preparePoolInitializerData } from "test/integration/UniswapV4Initializer.t.sol";
import { UNISWAP_V3_FACTORY_MAINNET } from "test/shared/Addresses.sol";
import { defaultDopplerERC20V1FactoryData } from "test/shared/DopplerERC20V1FactoryHelper.sol";

contract DopplerERC20V1FactoryUniswapV4InitializerNoOpGovernanceFactoryNoOpMigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        super.setUp();

        name = "DopplerERC20V1FactoryUniswapV4InitializerNoOpGovernanceFactoryNoOpMigrator";

        DopplerERC20V1Factory tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData = defaultDopplerERC20V1FactoryData();

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
    }
}

contract DopplerERC20V1FactoryDopplerHookInitializerNoOpGovernanceFactoryNoOpMigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        super.setUp();

        name = "DopplerERC20V1FactoryDopplerHookInitializerNoOpGovernanceFactoryNoOpMigrator";

        DopplerERC20V1Factory tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        createParams.tokenFactoryData = defaultDopplerERC20V1FactoryData();

        DopplerHookInitializer initializer =
            deployDopplerHookMulticurveInitializer(vm, _deployCodeTo, airlock, AIRLOCK_OWNER, address(manager));
        createParams.poolInitializer = initializer;
        createParams.poolInitializerData = prepareDopplerHookMulticurveInitializerData(address(0), address(0));
        createParams.salt = bytes32(uint256(1));
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }
}

contract DopplerERC20V1FactoryLockableUniswapV3InitializerNoOpGovernanceFactoryNoOpMigratorIntegrationTest is
    BaseIntegrationTest
{
    function setUp() public override {
        vm.createSelectFork(vm.envString("ETH_MAINNET_RPC_URL"), 21_093_509);
        super.setUp();

        name = "DopplerERC20V1FactoryLockableUniswapV3InitializerNoOpGovernanceFactoryNoOpMigrator";

        TestERC20 numeraire = new TestERC20(0);
        bytes32 salt = bytes32(uint256(123));

        DopplerERC20V1Factory tokenFactory = deployTokenFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.tokenFactory = tokenFactory;
        (address predictedAsset, bytes memory tokenFactoryData) =
            prepareTokenFactoryData(vm, address(airlock), address(tokenFactory), salt);
        createParams.tokenFactoryData = tokenFactoryData;
        createParams.numeraire = address(numeraire);

        LockableUniswapV3Initializer initializer =
            new LockableUniswapV3Initializer(address(airlock), IUniswapV3Factory(UNISWAP_V3_FACTORY_MAINNET));
        address[] memory modules = new address[](1);
        modules[0] = address(initializer);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.PoolInitializer;
        vm.prank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);

        bool isToken0 = predictedAsset < address(numeraire);
        createParams.poolInitializer = initializer;
        createParams.poolInitializerData = abi.encode(
            LockableUniswapV3InitData({
                fee: 3000,
                tickLower: isToken0 ? int24(-200_040) : int24(167_520),
                tickUpper: isToken0 ? int24(-167_520) : int24(200_040),
                numPositions: 10,
                maxShareToBeSold: 0.9 ether,
                beneficiaries: new BeneficiaryData[](0)
            })
        );
        createParams.salt = salt;
        createParams.numTokensToSell = 1e23;
        createParams.initialSupply = 1e23;

        NoOpMigrator migrator = deployNoOpMigrator(vm, airlock, AIRLOCK_OWNER);
        createParams.liquidityMigrator = migrator;

        NoOpGovernanceFactory governanceFactory = deployNoOpGovernanceFactory(vm, airlock, AIRLOCK_OWNER);
        createParams.governanceFactory = governanceFactory;
    }
}
