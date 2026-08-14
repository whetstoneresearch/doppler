// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import {
    InitData as LockableUniswapV3InitData,
    LockableUniswapV3Initializer
} from "src/initializers/LockableUniswapV3Initializer.sol";
import { DopplerDeployer, UniswapV4Initializer } from "src/initializers/UniswapV4Initializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { MineV4Params, mineV4 } from "test/shared/AirlockMiner.sol";
import { dopplerERC20V1FactoryData, predictDopplerERC20V1Address } from "test/shared/DopplerERC20V1FactoryHelper.sol";

contract UnsupportedInitializerLiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes calldata) external pure returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable returns (uint256) {
        return 0;
    }
}

contract BundlerUnsupportedInitializersIntegrationTest is Deployers {
    uint128 internal constant DEV_BUY_AMOUNT = 1 ether;
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    address internal airlockOwner = makeAddr("unsupportedAirlockOwner");
    address internal payer = makeAddr("unsupportedPayer");
    address internal recipient = makeAddr("unsupportedRecipient");

    Airlock internal airlock;
    Bundler internal bundler;
    DopplerERC20V1Factory internal tokenFactory;
    GovernanceFactory internal governanceFactory;
    UnsupportedInitializerLiquidityMigratorMock internal liquidityMigrator;
    TestERC20 internal erc20Numeraire;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_MAINNET_RPC_URL"), 21_093_509);

        deployFreshManagerAndRouters();

        airlock = new Airlock(airlockOwner);
        tokenFactory = new DopplerERC20V1Factory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        liquidityMigrator = new UnsupportedInitializerLiquidityMigratorMock();
        erc20Numeraire = new TestERC20(1e48);
        bundler = new Bundler(airlock, manager);

        address[] memory modules = new address[](3);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(liquidityMigrator);

        ModuleState[] memory states = new ModuleState[](3);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.LiquidityMigrator;

        vm.prank(airlockOwner);
        airlock.setModuleState(modules, states);
    }

    function test_bundleAndSimulateBundle_LockableUniswapV3Initializer_RevertAtomically() public {
        (CreateParams memory params, address predictedAsset, IUniswapV3Factory v3Factory) =
            _lockableUniswapV3CreateParams();

        _expectUnsupportedInitializerBoundary(params, predictedAsset);
        vm.expectRevert();
        bundler.simulateBundle(params, DEV_BUY_AMOUNT);

        _assertLaunchRolledBack(predictedAsset);
        assertEq(
            v3Factory.getPool(predictedAsset, address(erc20Numeraire), 3000),
            address(0),
            "simulation must revert the V3 pool"
        );

        erc20Numeraire.transfer(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        erc20Numeraire.approve(address(bundler), DEV_BUY_AMOUNT);
        uint256 payerBalanceBefore = erc20Numeraire.balanceOf(payer);

        _expectUnsupportedInitializerBoundary(params, predictedAsset);
        vm.prank(payer);
        vm.expectRevert();
        bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, recipient);

        _assertLaunchRolledBack(predictedAsset);
        assertEq(
            v3Factory.getPool(predictedAsset, address(erc20Numeraire), 3000),
            address(0),
            "bundle must revert the V3 pool"
        );
        assertEq(erc20Numeraire.balanceOf(payer), payerBalanceBefore, "failed bundle must not spend payer funds");
        assertEq(erc20Numeraire.balanceOf(address(bundler)), 0, "failed bundle must not retain payer funds");
        assertEq(erc20Numeraire.balanceOf(address(airlock)), 0, "failed launch must not retain numeraire");
    }

    function test_bundleAndSimulateBundle_UniswapV4Initializer_RevertAtomically() public {
        (CreateParams memory params, address predictedAsset, address predictedHook) = _uniswapV4CreateParams();

        _expectUnsupportedInitializerBoundary(params, predictedAsset);
        vm.expectRevert();
        bundler.simulateBundle(params, DEV_BUY_AMOUNT);

        _assertLaunchRolledBack(predictedAsset);
        assertEq(predictedHook.code.length, 0, "simulation must revert the V4 hook");

        vm.deal(payer, DEV_BUY_AMOUNT);
        uint256 payerBalanceBefore = payer.balance;

        _expectUnsupportedInitializerBoundary(params, predictedAsset);
        vm.prank(payer);
        vm.expectRevert();
        bundler.bundle{ value: DEV_BUY_AMOUNT }(params, _noVesting(), DEV_BUY_AMOUNT, recipient);

        _assertLaunchRolledBack(predictedAsset);
        assertEq(predictedHook.code.length, 0, "bundle must revert the V4 hook");
        assertEq(payer.balance, payerBalanceBefore, "failed bundle must not spend payer funds");
        assertEq(address(bundler).balance, 0, "failed bundle must not retain payer funds");
        assertEq(address(airlock).balance, 0, "failed launch must not retain native numeraire");
    }

    function _lockableUniswapV3CreateParams()
        internal
        returns (CreateParams memory params, address predictedAsset, IUniswapV3Factory v3Factory)
    {
        v3Factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);

        LockableUniswapV3Initializer lockableInitializer = new LockableUniswapV3Initializer(address(airlock), v3Factory);
        _registerPoolInitializer(IPoolInitializer(address(lockableInitializer)));

        bytes32 salt = keccak256("Bundler LockableUniswapV3Initializer regression");
        predictedAsset = predictDopplerERC20V1Address(tokenFactory, salt);
        bool assetIsToken0 = predictedAsset < address(erc20Numeraire);
        bytes memory initializerData = abi.encode(
            LockableUniswapV3InitData({
                fee: 3000,
                tickLower: assetIsToken0 ? int24(-200_040) : int24(167_520),
                tickUpper: assetIsToken0 ? int24(-167_520) : int24(200_040),
                numPositions: 10,
                maxShareToBeSold: 0.9 ether,
                beneficiaries: new BeneficiaryData[](0)
            })
        );

        params = _unsupportedInitializerCreateParams(
            address(erc20Numeraire),
            1e23,
            salt,
            IPoolInitializer(address(lockableInitializer)),
            initializerData,
            _unsupportedInitializerTokenFactoryData()
        );
    }

    function _uniswapV4CreateParams()
        internal
        returns (CreateParams memory params, address predictedAsset, address predictedHook)
    {
        DopplerDeployer deployer = new DopplerDeployer(manager);
        UniswapV4Initializer uniswapV4Initializer = new UniswapV4Initializer(address(airlock), manager, deployer);
        _registerPoolInitializer(IPoolInitializer(address(uniswapV4Initializer)));

        uint256 launchSupply = 1e23;
        bytes memory tokenFactoryData = _unsupportedInitializerTokenFactoryData();
        bytes memory initializerData = abi.encode(
            0.01 ether,
            10 ether,
            block.timestamp,
            block.timestamp + 1 days,
            int24(6000),
            int24(60_000),
            uint256(200),
            int24(800),
            false,
            uint256(10),
            uint24(200),
            int24(2)
        );
        MineV4Params memory miningParams = MineV4Params({
            airlock: address(airlock),
            poolManager: address(manager),
            initialSupply: launchSupply,
            numTokensToSell: launchSupply,
            numeraire: address(0),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: tokenFactoryData,
            poolInitializer: uniswapV4Initializer,
            poolInitializerData: initializerData
        });
        bytes32 salt;
        (salt, predictedHook, predictedAsset) = mineV4(miningParams);

        params = _unsupportedInitializerCreateParams(
            address(0),
            launchSupply,
            salt,
            IPoolInitializer(address(uniswapV4Initializer)),
            initializerData,
            tokenFactoryData
        );
    }

    function _unsupportedInitializerCreateParams(
        address numeraire,
        uint256 launchSupply,
        bytes32 salt,
        IPoolInitializer poolInitializer,
        bytes memory poolInitializerData,
        bytes memory tokenFactoryData
    ) internal view returns (CreateParams memory params) {
        params = CreateParams({
            initialSupply: launchSupply,
            numTokensToSell: launchSupply,
            numeraire: numeraire,
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: tokenFactoryData,
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: _governanceFactoryData(),
            poolInitializer: poolInitializer,
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(liquidityMigrator),
            liquidityMigratorData: bytes(""),
            integrator: address(0),
            salt: salt
        });
    }

    function _unsupportedInitializerTokenFactoryData() internal pure returns (bytes memory) {
        return dopplerERC20V1FactoryData(
            "Unsupported Bundler Test", "UNSUPPORTED", "TOKEN_URI", 0, 0, address(0), new address[](0)
        );
    }

    function _registerPoolInitializer(IPoolInitializer poolInitializer) internal {
        address[] memory modules = new address[](1);
        modules[0] = address(poolInitializer);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.PoolInitializer;
        vm.prank(airlockOwner);
        airlock.setModuleState(modules, states);
    }

    function _expectUnsupportedInitializerBoundary(CreateParams memory params, address predictedAsset) internal {
        vm.expectCall(
            address(params.poolInitializer),
            abi.encodeCall(
                IPoolInitializer.initialize,
                (predictedAsset, params.numeraire, params.numTokensToSell, params.salt, params.poolInitializerData)
            )
        );
        vm.expectCall(
            address(params.poolInitializer),
            abi.encodeWithSelector(bytes4(keccak256("getState(address)")), predictedAsset)
        );
    }

    function _assertLaunchRolledBack(address predictedAsset) internal view {
        assertEq(predictedAsset.code.length, 0, "failed launch must revert asset deployment");
        (
            ,
            address storedTimelock,
            address storedGovernance,,
            IPoolInitializer storedInitializer,
            address storedPool,,
            uint256 storedNumTokensToSell,
            uint256 storedTotalSupply,
            address storedIntegrator
        ) = airlock.getAssetData(predictedAsset);
        assertEq(storedTimelock, address(0), "failed launch must not retain a timelock");
        assertEq(storedGovernance, address(0), "failed launch must not retain governance");
        assertEq(address(storedInitializer), address(0), "failed launch must not retain its initializer");
        assertEq(storedPool, address(0), "failed launch must not retain its pool");
        assertEq(storedNumTokensToSell, 0, "failed launch must not retain sale state");
        assertEq(storedTotalSupply, 0, "failed launch must not retain supply state");
        assertEq(storedIntegrator, address(0), "failed launch must not retain an integrator");
    }

    function _noVesting() internal pure returns (Bundler.VestingParams memory) {
        return Bundler.VestingParams({ permissionlessClaim: false, vestingDuration: 0, cliffDuration: 0 });
    }

    function _governanceFactoryData() internal pure returns (bytes memory) {
        return abi.encode("Bundler Test", uint48(7200), uint32(50_400), uint256(0));
    }
}
