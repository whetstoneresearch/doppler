// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import {
    Bundled,
    Bundler,
    ExactInputAmountZero,
    ExactInputNotFullySpent,
    InvalidAddress,
    InvalidNativeValue,
    InvalidPool,
    InvalidRecipient,
    SenderNotPoolManager,
    SenderNotSelf
} from "src/Bundler.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHookInitializer.sol";
import { RehypeDopplerHookInitializer } from "src/dopplerHooks/RehypeDopplerHookInitializer.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import {
    AIRLOCK_OWNER_FEE_BPS,
    BPS_DENOMINATOR,
    FeeDistributionInfo,
    FeeRoutingMode,
    InitData as RehypeInitData,
    IntegratorInitConfig,
    SWAP_FEE_DENOMINATOR
} from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";
import { dopplerERC20V1FactoryData, predictDopplerERC20V1Address } from "test/shared/DopplerERC20V1FactoryHelper.sol";

contract BundlerLiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes calldata) external pure returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable returns (uint256) {
        return 0;
    }
}

contract InvalidPoolInitializerMock is IPoolInitializer {
    function initialize(address asset, address, uint256, bytes32, bytes calldata) external pure returns (address) {
        return asset;
    }

    function exitLiquidity(address)
        external
        pure
        returns (uint160, address, uint128, uint128, address, uint128, uint128)
    {
        revert();
    }

    function getState(address)
        external
        pure
        returns (address, uint256, address, bytes memory, PoolStatus, PoolKey memory, int24)
    {
        PoolKey memory poolKey;
        poolKey.currency0 = Currency.wrap(address(1));
        poolKey.currency1 = Currency.wrap(address(2));
        return (address(0), 0, address(0), bytes(""), PoolStatus.Initialized, poolKey, 0);
    }
}

contract BundlerIntegrationTest is Deployers {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant START_FEE = 800_000;
    uint128 internal constant DEV_BUY_AMOUNT = 1 ether;
    uint256 internal constant INITIAL_SUPPLY = 1e27;

    address internal airlockOwner = makeAddr("airlockOwner");
    address internal buybackDst = makeAddr("buybackDst");
    address internal payer = makeAddr("payer");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");

    Airlock internal airlock;
    Bundler internal bundler;
    DopplerHookInitializer internal initializer;
    DopplerERC20V1Factory internal tokenFactory;
    GovernanceFactory internal governanceFactory;
    BundlerLiquidityMigratorMock internal liquidityMigrator;
    RehypeDopplerHookInitializer internal rehype;
    TestERC20 internal erc20Numeraire;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(airlockOwner);
        tokenFactory = new DopplerERC20V1Factory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        liquidityMigrator = new BundlerLiquidityMigratorMock();
        erc20Numeraire = new TestERC20(1e48);

        initializer = DopplerHookInitializer(
            payable(address(
                    uint160(
                        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                    ) ^ (0x4444 << 144)
                ))
        );
        deployCodeTo("DopplerHookInitializer", abi.encode(address(airlock), address(manager)), address(initializer));

        bundler = new Bundler(airlock, manager);
        rehype = new RehypeDopplerHookInitializer(address(initializer), manager, address(bundler));

        address[] memory modules = new address[](4);
        modules[0] = address(tokenFactory);
        modules[1] = address(governanceFactory);
        modules[2] = address(initializer);
        modules[3] = address(liquidityMigrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        vm.startPrank(airlockOwner);
        airlock.setModuleState(modules, states);

        address[] memory hooks = new address[](1);
        hooks[0] = address(rehype);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;
        initializer.setDopplerHookState(hooks, flags);
        vm.stopPrank();
    }

    function test_bundle_ERC20Numeraire_AssetCurrency0_PaysOnlyOwnerFeeAndUsesRecipient() public {
        bytes32 salt = _saltForAssetOrientation(address(erc20Numeraire), true, 1);
        _assertERC20Bundle(salt, true);
    }

    function test_bundle_ERC20Numeraire_AssetCurrency1_PaysOnlyOwnerFeeAndUsesRecipient() public {
        bytes32 salt = _saltForAssetOrientation(address(erc20Numeraire), false, 1000);
        _assertERC20Bundle(salt, false);
    }

    function test_bundle_NativeNumeraire_SpendsAllValueAndPaysOnlyOwnerFee() public {
        bytes32 salt = bytes32(uint256(2000));
        (CreateParams memory params, address predictedAsset) = _createParams(address(0), salt, START_FEE);
        InitData memory initializerData = abi.decode(params.poolInitializerData, (InitData));
        RehypeInitData memory rehypeData =
            abi.decode(initializerData.onInitializationDopplerHookCalldata, (RehypeInitData));
        rehypeData.integratorConfig.integrator = makeAddr("integrator");
        rehypeData.integratorConfig.feeShare = 200_000;
        rehypeData.integratorConfig.assetFeesToNumeraireRatio = 1_000_000_000;
        initializerData.onInitializationDopplerHookCalldata = abi.encode(rehypeData);
        params.poolInitializerData = abi.encode(initializerData);

        vm.deal(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut) =
            bundler.bundle{ value: DEV_BUY_AMOUNT }(params, _noVesting(), DEV_BUY_AMOUNT, recipient);

        _assertCreationOutputs(asset, poolKey, governance, timelock, predictedAsset, address(0));
        _assertGovernanceDeployed(governance, timelock);
        assertGt(amountOut, 0);
        assertEq(asset.balance, 0, "asset must be an ERC20, not native output");
        assertEq(TestERC20(asset).balanceOf(recipient), amountOut);
        assertEq(TestERC20(asset).balanceOf(payer), 0);
        assertEq(payer.balance, 0, "successful exact-input dev buy must consume all supplied ETH");
        assertEq(address(bundler).balance, 0, "Bundler must not retain native numeraire");

        (,,,,, PoolKey memory key,) = initializer.getState(asset);
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), asset);
        assertEq(PoolId.unwrap(poolKey.toId()), PoolId.unwrap(key.toId()));
        _assertOwnerOnlyDevBuyFee(key.toId(), key, amountOut);
        (uint128 pending0, uint128 pending1) = rehype.getPendingIntegratorFees(key.toId());
        (uint128 claimable0, uint128 claimable1) = rehype.getClaimableIntegratorFees(key.toId());
        assertEq(
            uint256(pending0) + pending1 + claimable0 + claimable1, 0, "dev buy must exempt configured integrator fees"
        );
    }

    function test_simulateBundle_ERC20Numeraire_ReturnsExactBundleResultAndRevertsState() public {
        bytes32 salt = bytes32(uint256(2500));
        (CreateParams memory params, address predictedAsset) = _createParams(address(erc20Numeraire), salt, START_FEE);

        vm.prank(payer);
        (
            address quotedAsset,
            PoolKey memory quotedPoolKey,
            address quotedGovernance,
            address quotedTimelock,
            uint128 quotedAmountOut
        ) = bundler.simulateBundle(params, DEV_BUY_AMOUNT);

        _assertCreationOutputs(
            quotedAsset, quotedPoolKey, quotedGovernance, quotedTimelock, predictedAsset, address(erc20Numeraire)
        );
        assertGt(quotedAmountOut, 0);
        assertEq(predictedAsset.code.length, 0, "simulation must revert asset deployment");
        assertEq(quotedGovernance.code.length, 0, "simulation must revert governance deployment");
        assertEq(quotedTimelock.code.length, 0, "simulation must revert timelock deployment");
        assertEq(erc20Numeraire.balanceOf(payer), 0, "simulation must not require or spend numeraire");

        erc20Numeraire.transfer(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        erc20Numeraire.approve(address(bundler), DEV_BUY_AMOUNT);
        vm.expectEmit(true, false, false, true, address(bundler));
        emit Bundled(recipient, DEV_BUY_AMOUNT, quotedAmountOut, quotedPoolKey);
        vm.prank(payer);
        (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut) =
            bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, recipient);

        assertEq(asset, quotedAsset);
        assertEq(PoolId.unwrap(poolKey.toId()), PoolId.unwrap(quotedPoolKey.toId()));
        assertEq(governance, quotedGovernance, "simulation must return exact governance address");
        assertEq(timelock, quotedTimelock, "simulation must return exact timelock address");
        _assertGovernanceDeployed(governance, timelock);
        assertEq(amountOut, quotedAmountOut, "simulation must return the exact bundle output");
    }

    function test_simulateBundle_NativeNumeraire_DoesNotRequireValueAndReturnsExactOutput() public {
        bytes32 salt = bytes32(uint256(2600));
        (CreateParams memory params, address predictedAsset) = _createParams(address(0), salt, START_FEE);

        vm.prank(payer);
        (
            address quotedAsset,
            PoolKey memory quotedPoolKey,
            address quotedGovernance,
            address quotedTimelock,
            uint128 quotedAmountOut
        ) = bundler.simulateBundle(params, DEV_BUY_AMOUNT);

        _assertCreationOutputs(quotedAsset, quotedPoolKey, quotedGovernance, quotedTimelock, predictedAsset, address(0));
        assertEq(payer.balance, 0, "simulation must not require native value");
        assertEq(predictedAsset.code.length, 0, "simulation must revert asset deployment");

        vm.deal(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        (address asset, PoolKey memory poolKey,,, uint128 amountOut) =
            bundler.bundle{ value: DEV_BUY_AMOUNT }(params, _noVesting(), DEV_BUY_AMOUNT, recipient);

        assertEq(asset, quotedAsset);
        assertEq(PoolId.unwrap(poolKey.toId()), PoolId.unwrap(quotedPoolKey.toId()));
        assertEq(amountOut, quotedAmountOut, "simulation must return the exact bundle output");
    }

    function test_bundle_PlainDopplerHookInitializer_SpendsExactInputAndTransfersOutputToRecipient() public {
        (CreateParams memory params, address predictedAsset) =
            _createPlainDopplerParams(address(erc20Numeraire), bytes32(uint256(2700)));

        erc20Numeraire.transfer(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        erc20Numeraire.approve(address(bundler), DEV_BUY_AMOUNT);

        vm.prank(payer);
        (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut) =
            bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, recipient);

        _assertPlainDopplerCreationOutputs(
            asset, poolKey, governance, timelock, predictedAsset, address(erc20Numeraire)
        );
        _assertGovernanceDeployed(governance, timelock);
        assertGt(amountOut, 0, "exact-input buy must return asset tokens");
        assertEq(erc20Numeraire.balanceOf(payer), 0, "exact-input buy must consume the full payer input");
        assertEq(erc20Numeraire.balanceOf(address(bundler)), 0, "Bundler must not retain numeraire");
        assertEq(TestERC20(asset).balanceOf(recipient), amountOut, "recipient must receive the quoted output");
        assertEq(TestERC20(asset).balanceOf(payer), 0, "payer must not receive output sent to the recipient");
        _assertPlainDopplerPool(asset, poolKey);
    }

    function test_simulateBundle_PlainDopplerHookInitializer_RevertsStateAndMatchesExecution() public {
        (CreateParams memory params, address predictedAsset) =
            _createPlainDopplerParams(address(erc20Numeraire), bytes32(uint256(2800)));

        vm.prank(payer);
        (
            address quotedAsset,
            PoolKey memory quotedPoolKey,
            address quotedGovernance,
            address quotedTimelock,
            uint128 quotedAmountOut
        ) = bundler.simulateBundle(params, DEV_BUY_AMOUNT);

        _assertPlainDopplerCreationOutputs(
            quotedAsset, quotedPoolKey, quotedGovernance, quotedTimelock, predictedAsset, address(erc20Numeraire)
        );
        assertGt(quotedAmountOut, 0, "simulation must quote real output");
        assertEq(predictedAsset.code.length, 0, "simulation must revert asset deployment");
        assertEq(quotedGovernance.code.length, 0, "simulation must revert governance deployment");
        assertEq(quotedTimelock.code.length, 0, "simulation must revert timelock deployment");
        (,,,, PoolStatus statusAfterSimulation,,) = initializer.getState(predictedAsset);
        assertEq(
            uint8(statusAfterSimulation),
            uint8(PoolStatus.Uninitialized),
            "simulation must revert initializer launch state"
        );
        assertEq(erc20Numeraire.balanceOf(payer), 0, "simulation must not require or spend numeraire");

        erc20Numeraire.transfer(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        erc20Numeraire.approve(address(bundler), DEV_BUY_AMOUNT);
        vm.prank(payer);
        (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut) =
            bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, recipient);

        assertEq(asset, quotedAsset, "simulation must return the exact asset address");
        assertEq(PoolId.unwrap(poolKey.toId()), PoolId.unwrap(quotedPoolKey.toId()), "simulation pool must match");
        assertEq(governance, quotedGovernance, "simulation must return the exact governance address");
        assertEq(timelock, quotedTimelock, "simulation must return the exact timelock address");
        assertEq(amountOut, quotedAmountOut, "simulation must return the exact bundle output");
        assertEq(erc20Numeraire.balanceOf(payer), 0, "executed exact-input buy must consume the full payer input");
        assertEq(erc20Numeraire.balanceOf(address(bundler)), 0, "Bundler must not retain numeraire");
        assertEq(TestERC20(asset).balanceOf(recipient), amountOut, "recipient must receive the quoted output");
        assertEq(TestERC20(asset).balanceOf(payer), 0, "payer must not receive output sent to the recipient");
        _assertGovernanceDeployed(governance, timelock);
        _assertPlainDopplerPool(asset, poolKey);
    }

    function test_bundle_NextSwapPaysNormalRehypeFee() public {
        bytes32 salt = bytes32(uint256(3000));
        (CreateParams memory params, address predictedAsset) = _createParams(address(erc20Numeraire), salt, START_FEE);

        erc20Numeraire.transfer(payer, 2 * DEV_BUY_AMOUNT);
        vm.prank(payer);
        erc20Numeraire.approve(address(bundler), DEV_BUY_AMOUNT);
        vm.prank(payer);
        (address asset,,,,) = bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, recipient);
        assertEq(asset, predictedAsset);

        (,,,,, PoolKey memory key,) = initializer.getState(asset);
        PoolId id = key.toId();
        (, uint256 beneficiaryBefore,) = _assetFeeBuckets(id, key, asset);
        assertEq(beneficiaryBefore, 0, "dev buy must not accrue ordinary Rehype fees");

        erc20Numeraire.transfer(attacker, DEV_BUY_AMOUNT);
        vm.startPrank(attacker);
        erc20Numeraire.approve(address(swapRouter), DEV_BUY_AMOUNT);
        swapRouter.swap(
            key,
            _buyParams(key, address(erc20Numeraire), DEV_BUY_AMOUNT),
            PoolSwapTest.TestSettings(false, false),
            bytes("")
        );
        vm.stopPrank();

        (, uint256 beneficiaryAfter,) = _assetFeeBuckets(id, key, asset);
        assertGt(beneficiaryAfter, beneficiaryBefore, "post-dev-buy swap must pay ordinary Rehype fees");
    }

    function test_directCreate_ThirdPartyCannotStealDevBuyExemption() public {
        bytes32 salt = bytes32(uint256(4000));
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), salt, START_FEE);
        (address asset,,,,) = airlock.create(params);
        (,,,,, PoolKey memory key,) = initializer.getState(asset);
        PoolId id = key.toId();

        erc20Numeraire.transfer(attacker, 2 * DEV_BUY_AMOUNT);
        vm.startPrank(attacker);
        erc20Numeraire.approve(address(swapRouter), 2 * DEV_BUY_AMOUNT);

        swapRouter.swap(
            key,
            _buyParams(key, address(erc20Numeraire), DEV_BUY_AMOUNT),
            PoolSwapTest.TestSettings(false, false),
            bytes("")
        );
        (, uint256 beneficiaryAfterFirst,) = _assetFeeBuckets(id, key, asset);
        assertGt(beneficiaryAfterFirst, 0, "first swap must pay ordinary Rehype fee");

        swapRouter.swap(
            key,
            _buyParams(key, address(erc20Numeraire), DEV_BUY_AMOUNT),
            PoolSwapTest.TestSettings(false, false),
            bytes("")
        );
        vm.stopPrank();

        (, uint256 beneficiaryAfterSecond,) = _assetFeeBuckets(id, key, asset);
        assertGt(beneficiaryAfterSecond, beneficiaryAfterFirst, "external sender must never consume the exemption");
    }

    function test_bundle_RevertsWhenExactInputIsZero() public {
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), bytes32(uint256(5000)), START_FEE);
        vm.expectRevert(ExactInputAmountZero.selector);
        bundler.bundle(params, _noVesting(), 0, recipient);
    }

    function test_bundle_RevertsWhenRecipientIsZero() public {
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), bytes32(uint256(5001)), START_FEE);
        vm.expectRevert(InvalidRecipient.selector);
        bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, address(0));
    }

    function test_bundle_RevertsWhenERC20BuySendsNativeValue() public {
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), bytes32(uint256(5002)), START_FEE);
        vm.deal(address(this), 1);
        vm.expectRevert(InvalidNativeValue.selector);
        bundler.bundle{ value: 1 }(params, _noVesting(), DEV_BUY_AMOUNT, recipient);
    }

    function test_bundle_RevertsWhenNativeValueDoesNotEqualExactInput() public {
        (CreateParams memory params,) = _createParams(address(0), bytes32(uint256(5003)), START_FEE);
        vm.deal(address(this), DEV_BUY_AMOUNT - 1);
        vm.expectRevert(InvalidNativeValue.selector);
        bundler.bundle{ value: DEV_BUY_AMOUNT - 1 }(params, _noVesting(), DEV_BUY_AMOUNT, recipient);
    }

    function test_bundle_RevertsWhenNativeValueExceedsExactInput() public {
        (CreateParams memory params,) = _createParams(address(0), bytes32(uint256(5007)), START_FEE);
        vm.deal(address(this), DEV_BUY_AMOUNT + 1);

        vm.expectRevert(InvalidNativeValue.selector);
        bundler.bundle{ value: DEV_BUY_AMOUNT + 1 }(params, _noVesting(), DEV_BUY_AMOUNT, recipient);
    }

    function test_bundle_RevertsWhenERC20AllowanceIsMissing() public {
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), bytes32(uint256(5004)), START_FEE);
        erc20Numeraire.transfer(payer, DEV_BUY_AMOUNT);

        vm.prank(payer);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, recipient);
    }

    function test_bundle_RevertsWhenPoolCannotSpendFullExactInput() public {
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), bytes32(uint256(5005)), START_FEE);
        uint128 excessiveInput = type(uint128).max;
        erc20Numeraire.transfer(payer, excessiveInput);
        vm.prank(payer);
        erc20Numeraire.approve(address(bundler), excessiveInput);

        vm.prank(payer);
        vm.expectPartialRevert(ExactInputNotFullySpent.selector);
        bundler.bundle(params, _noVesting(), excessiveInput, recipient);
    }

    function test_bundle_RevertsWhenInitializerReturnsDifferentPair() public {
        InvalidPoolInitializerMock invalidInitializer = new InvalidPoolInitializerMock();
        address[] memory modules = new address[](1);
        modules[0] = address(invalidInitializer);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.PoolInitializer;
        vm.prank(airlockOwner);
        airlock.setModuleState(modules, states);

        CreateParams memory params = CreateParams({
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: INITIAL_SUPPLY,
            numeraire: address(erc20Numeraire),
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: dopplerERC20V1FactoryData(
                "Invalid Pool", "BAD", "TOKEN_URI", 0, 0, address(0), new address[](0)
            ),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: _governanceFactoryData(),
            poolInitializer: IPoolInitializer(address(invalidInitializer)),
            poolInitializerData: bytes(""),
            liquidityMigrator: ILiquidityMigrator(liquidityMigrator),
            liquidityMigratorData: bytes(""),
            integrator: address(0),
            salt: bytes32(uint256(5006))
        });
        address predictedAsset = predictDopplerERC20V1Address(tokenFactory, params.salt);
        vm.expectRevert(InvalidPool.selector);
        bundler.simulateBundle(params, DEV_BUY_AMOUNT);
        assertEq(predictedAsset.code.length, 0, "failed simulation must revert asset deployment");

        vm.expectRevert(InvalidPool.selector);
        bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, recipient);
    }

    function testFuzz_simulateBundle_ReturnsExactExecutionResult(uint128 fuzzedAmountIn) public {
        uint128 amountIn = uint128(bound(fuzzedAmountIn, 1e6, 100 ether));
        bytes32 salt = keccak256(abi.encode("fuzz bundle", fuzzedAmountIn));
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), salt, START_FEE);

        (
            address quotedAsset,
            PoolKey memory quotedPoolKey,
            address quotedGovernance,
            address quotedTimelock,
            uint128 quotedAmountOut
        ) = bundler.simulateBundle(params, amountIn);

        erc20Numeraire.transfer(payer, amountIn);
        vm.startPrank(payer);
        erc20Numeraire.approve(address(bundler), amountIn);
        (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut) =
            bundler.bundle(params, _noVesting(), amountIn, recipient);
        vm.stopPrank();

        assertEq(asset, quotedAsset);
        assertEq(PoolId.unwrap(poolKey.toId()), PoolId.unwrap(quotedPoolKey.toId()));
        assertEq(governance, quotedGovernance);
        assertEq(timelock, quotedTimelock);
        assertEq(amountOut, quotedAmountOut);
        assertEq(TestERC20(asset).balanceOf(recipient), amountOut);
    }

    function test_simulateBundle_RevertsWhenExactInputIsZero() public {
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), bytes32(uint256(5100)), START_FEE);

        vm.expectRevert(ExactInputAmountZero.selector);
        bundler.simulateBundle(params, 0);
    }

    function test_simulateBundle_BubblesSwapFailureAndRevertsCreation() public {
        (CreateParams memory params, address predictedAsset) =
            _createParams(address(erc20Numeraire), bytes32(uint256(5101)), START_FEE);

        vm.expectPartialRevert(ExactInputNotFullySpent.selector);
        bundler.simulateBundle(params, type(uint128).max);

        assertEq(predictedAsset.code.length, 0, "failed simulation must revert asset deployment");
    }

    function test_simulateBundleHelper_RevertsForExternalCaller() public {
        (CreateParams memory params,) = _createParams(address(erc20Numeraire), bytes32(uint256(5102)), START_FEE);

        vm.expectRevert(SenderNotSelf.selector);
        bundler._simulateBundle(params, DEV_BUY_AMOUNT);
    }

    function test_unlockCallback_RevertsForExternalCaller() public {
        vm.expectRevert(SenderNotPoolManager.selector);
        bundler.unlockCallback(bytes(""));
    }

    function test_constructor_RevertsForZeroDependencies() public {
        vm.expectRevert(InvalidAddress.selector);
        new Bundler(Airlock(payable(address(0))), manager);

        vm.expectRevert(InvalidAddress.selector);
        new Bundler(airlock, IPoolManager(address(0)));
    }

    function _assertERC20Bundle(bytes32 salt, bool assetIsCurrency0) internal {
        (CreateParams memory params, address predictedAsset) = _createParams(address(erc20Numeraire), salt, START_FEE);
        assertEq(predictedAsset < address(erc20Numeraire), assetIsCurrency0, "unexpected test orientation");

        erc20Numeraire.transfer(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        erc20Numeraire.approve(address(bundler), DEV_BUY_AMOUNT);

        uint256 payerNumeraireBefore = erc20Numeraire.balanceOf(payer);
        vm.prank(payer);
        (address asset, PoolKey memory poolKey, address governance, address timelock, uint128 amountOut) =
            bundler.bundle(params, _noVesting(), DEV_BUY_AMOUNT, recipient);

        _assertCreationOutputs(asset, poolKey, governance, timelock, predictedAsset, address(erc20Numeraire));
        _assertGovernanceDeployed(governance, timelock);
        assertGt(amountOut, 0);
        assertEq(erc20Numeraire.balanceOf(payer), payerNumeraireBefore - DEV_BUY_AMOUNT);
        assertEq(erc20Numeraire.balanceOf(address(bundler)), 0);
        assertEq(TestERC20(asset).balanceOf(recipient), amountOut);
        assertEq(TestERC20(asset).balanceOf(payer), 0);

        (,,,,, PoolKey memory key,) = initializer.getState(asset);
        assertEq(Currency.unwrap(assetIsCurrency0 ? key.currency0 : key.currency1), asset);
        assertEq(Currency.unwrap(assetIsCurrency0 ? key.currency1 : key.currency0), address(erc20Numeraire));
        assertEq(PoolId.unwrap(poolKey.toId()), PoolId.unwrap(key.toId()));
        _assertOwnerOnlyDevBuyFee(key.toId(), key, amountOut);
    }

    function _assertCreationOutputs(
        address asset,
        PoolKey memory poolKey,
        address governance,
        address timelock,
        address predictedAsset,
        address numeraire
    ) internal view {
        assertEq(asset, predictedAsset);
        assertEq(Currency.unwrap(poolKey.currency0), asset < numeraire ? asset : numeraire);
        assertEq(Currency.unwrap(poolKey.currency1), asset < numeraire ? numeraire : asset);
        assertEq(poolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(poolKey.tickSpacing, 8);
        assertEq(address(poolKey.hooks), address(initializer));
        assertNotEq(governance, timelock, "governance and timelock must be distinct");
    }

    function _assertPlainDopplerCreationOutputs(
        address asset,
        PoolKey memory poolKey,
        address governance,
        address timelock,
        address predictedAsset,
        address numeraire
    ) internal view {
        assertEq(asset, predictedAsset);
        assertEq(Currency.unwrap(poolKey.currency0), asset < numeraire ? asset : numeraire);
        assertEq(Currency.unwrap(poolKey.currency1), asset < numeraire ? numeraire : asset);
        assertEq(poolKey.fee, 0, "plain Doppler pool must use its configured static fee");
        assertEq(poolKey.tickSpacing, 8);
        assertEq(address(poolKey.hooks), address(initializer));
        assertNotEq(governance, timelock, "governance and timelock must be distinct");
    }

    function _assertPlainDopplerPool(address asset, PoolKey memory bundledPoolKey) internal view {
        (,, address dopplerHook,,, PoolKey memory initializedPoolKey,) = initializer.getState(asset);
        assertEq(dopplerHook, address(0), "plain Doppler pool must not configure a Rehype hook");
        assertEq(
            PoolId.unwrap(initializedPoolKey.toId()),
            PoolId.unwrap(bundledPoolKey.toId()),
            "Bundler must return the initialized pool"
        );
        assertEq(_poolAsset(initializedPoolKey.toId()), address(0), "plain pool must not invoke Rehype initialization");
    }

    function _assertGovernanceDeployed(address governance, address timelock) internal view {
        assertTrue(governance.code.length > 0, "governance must be deployed");
        assertTrue(timelock.code.length > 0, "timelock must be deployed");
    }

    function _assertOwnerOnlyDevBuyFee(PoolId id, PoolKey memory key, uint256 netAmountOut) internal view {
        address asset = _poolAsset(id);
        (uint256 ownerFee, uint256 beneficiaryFee, uint256 pendingFee) = _assetFeeBuckets(id, key, asset);

        assertGt(ownerFee, 0, "dev buy must accrue the Airlock owner share");
        assertEq(beneficiaryFee, 0, "dev buy must exempt ordinary Rehype fees");
        assertEq(pendingFee, 0, "dev buy must not leave distributable fees pending");
        uint256 grossOutput = netAmountOut + ownerFee;
        uint256 assessedFee = grossOutput * START_FEE / SWAP_FEE_DENOMINATOR;
        uint256 expectedOwnerFee = assessedFee * AIRLOCK_OWNER_FEE_BPS / BPS_DENOMINATOR;
        assertEq(ownerFee, expectedOwnerFee, "owner must receive 5% of the otherwise assessed Rehype fee");
    }

    function _assetFeeBuckets(
        PoolId id,
        PoolKey memory key,
        address asset
    ) internal view returns (uint256 ownerFee, uint256 beneficiaryFee, uint256 pendingFee) {
        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 ownerFees0,
            uint128 ownerFees1,
        ) = rehype.getHookFees(id);

        if (Currency.unwrap(key.currency0) == asset) {
            return (ownerFees0, beneficiaryFees0, fees0);
        }
        return (ownerFees1, beneficiaryFees1, fees1);
    }

    function _poolAsset(PoolId id) internal view returns (address asset) {
        (asset,,) = rehype.getPoolInfo(id);
    }

    function _buyParams(
        PoolKey memory key,
        address numeraire,
        uint128 amountIn
    ) internal pure returns (IPoolManager.SwapParams memory) {
        bool zeroForOne = Currency.unwrap(key.currency0) == numeraire;
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(uint256(amountIn)),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _createParams(
        address numeraire,
        bytes32 salt,
        uint24 startFee
    ) internal view returns (CreateParams memory params, address predictedAsset) {
        predictedAsset = predictDopplerERC20V1Address(tokenFactory, salt);
        Curve[] memory curves = new Curve[](10);
        for (uint256 i; i < curves.length; ++i) {
            curves[i] =
                Curve({ tickLower: int24(uint24(i * 16_000)), tickUpper: 240_000, numPositions: 10, shares: WAD / 10 });
        }

        FeeDistributionInfo memory distribution = FeeDistributionInfo({
            assetFeesToAssetBuybackWad: 0,
            assetFeesToNumeraireBuybackWad: 0,
            assetFeesToBeneficiaryWad: uint64(WAD),
            assetFeesToLpWad: 0,
            numeraireFeesToAssetBuybackWad: 0,
            numeraireFeesToNumeraireBuybackWad: 0,
            numeraireFeesToBeneficiaryWad: uint64(WAD),
            numeraireFeesToLpWad: 0
        });

        RehypeInitData memory rehypeData = RehypeInitData({
            numeraire: numeraire,
            buybackDst: buybackDst,
            startFee: startFee,
            endFee: startFee,
            durationSeconds: 0,
            startingTime: 0,
            feeRoutingMode: FeeRoutingMode.DirectBuyback,
            feeDistributionInfo: distribution,
            feeBeneficiaries: new BeneficiaryData[](0),
            integratorConfig: IntegratorInitConfig({
                integrator: address(0),
                feeShare: 0,
                assetFeesToNumeraireRatio: 0,
                numeraireFeesToAssetRatio: 0,
                automaticPayout: false
            })
        });

        InitData memory initData = InitData({
            fee: 0,
            tickSpacing: 8,
            farTick: 200_000,
            curves: curves,
            beneficiaries: new BeneficiaryData[](0),
            dopplerHook: address(rehype),
            onInitializationDopplerHookCalldata: abi.encode(rehypeData),
            graduationDopplerHookCalldata: bytes("")
        });

        params = CreateParams({
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: INITIAL_SUPPLY,
            numeraire: numeraire,
            tokenFactory: ITokenFactory(tokenFactory),
            tokenFactoryData: dopplerERC20V1FactoryData(
                "Bundler Test", "BUNDLE", "TOKEN_URI", 0, 0, address(0), new address[](0)
            ),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: _governanceFactoryData(),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(liquidityMigrator),
            liquidityMigratorData: bytes(""),
            integrator: address(0),
            salt: salt
        });
    }

    function _createPlainDopplerParams(
        address numeraire,
        bytes32 salt
    ) internal view returns (CreateParams memory params, address predictedAsset) {
        (params, predictedAsset) = _createParams(numeraire, salt, 0);
        InitData memory initData = abi.decode(params.poolInitializerData, (InitData));
        initData.fee = 0;
        initData.dopplerHook = address(0);
        initData.onInitializationDopplerHookCalldata = bytes("");
        initData.graduationDopplerHookCalldata = bytes("");
        params.poolInitializerData = abi.encode(initData);
    }

    function _saltForAssetOrientation(
        address numeraire,
        bool assetIsCurrency0,
        uint256 seed
    ) internal view returns (bytes32) {
        for (uint256 i; i < 512; ++i) {
            bytes32 salt = bytes32(seed + i);
            if ((predictDopplerERC20V1Address(tokenFactory, salt) < numeraire) == assetIsCurrency0) return salt;
        }
        revert("orientation not found");
    }

    function _noVesting() internal pure returns (Bundler.VestingParams memory) {
        return Bundler.VestingParams({ permissionlessClaim: false, vestingDuration: 0, cliffDuration: 0 });
    }

    function _governanceFactoryData() internal pure returns (bytes memory) {
        return abi.encode("Bundler Test", uint48(7200), uint32(50_400), uint256(0));
    }
}
