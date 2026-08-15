// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@v4-core/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { console } from "forge-std/console.sol";
import { DeployBase } from "script/DeployBase.s.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { Bundler } from "src/Bundler.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHookInitializer.sol";
import { RehypeDopplerHookInitializer } from "src/dopplerHooks/RehypeDopplerHookInitializer.sol";
import { NoOpGovernanceFactory } from "src/governance/NoOpGovernanceFactory.sol";
import { DopplerHookInitializer, InitData } from "src/initializers/DopplerHookInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { NoOpMigrator } from "src/migrators/NoOpMigrator.sol";
import { DopplerERC20V1, VestingSchedule } from "src/tokens/DopplerERC20V1.sol";
import { DopplerERC20V1Factory } from "src/tokens/DopplerERC20V1Factory.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { FeeDistributionInfo, FeeRoutingMode, InitData as RehypeInitData } from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

/// @notice Thrown when this simulation-only script is invoked in a broadcast context.
error BroadcastForbidden();

/// @notice Reusable fork-only smoke test for the deployed priority launch stack.
/// @dev DeployDoppler invokes `_testDeployment` after its last broadcast transaction, so every test-only state
///      change stays in Forge's simulation. The standalone wrapper below rejects broadcast mode entirely.
abstract contract TestDeployment is DeployBase {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant TOKEN_VESTING_ALLOCATION = INITIAL_SUPPLY / 10;
    uint128 internal constant DEV_BUY_AMOUNT = 1 ether;
    uint128 internal constant FOLLOW_UP_BUY_AMOUNT = 0.01 ether;

    uint24 internal constant START_TAX = 800_000; // 80%
    uint24 internal constant END_TAX = 12_500; // 1.25%
    uint32 internal constant TAX_DECAY_DURATION = 60 seconds;

    uint64 internal constant DEV_BUY_VESTING_DURATION = 365 days;
    uint64 internal constant DEV_BUY_CLIFF_DURATION = 30 days;
    uint64 internal constant TOKEN_VESTING_DURATION = 730 days;
    uint64 internal constant TOKEN_VESTING_CLIFF = 365 days;

    address internal constant DEFAULT_TREASURY = address(0xBEEF);
    address internal constant TRADER = address(0xA11CE);

    struct Deployments {
        Airlock airlock;
        Bundler bundler;
        DopplerERC20V1Factory tokenFactory;
        NoOpGovernanceFactory governanceFactory;
        DopplerHookInitializer initializer;
        RehypeDopplerHookInitializer rehype;
        NoOpMigrator migrator;
        IPoolManager poolManager;
        address deployer;
        address treasury;
    }

    function _testDeployment(Deployments memory deployments)
        internal
        returns (address asset, PoolKey memory poolKey, uint128 devBuyAmountOut)
    {
        _validateDeployments(deployments);
        _whitelist(deployments);

        bytes32 salt = keccak256(abi.encode("TestDeployment", block.chainid));
        CreateParams memory createData = _createParams(deployments, salt);
        Bundler.VestingParams memory vestingData = Bundler.VestingParams({
            permissionlessClaim: false, vestingDuration: DEV_BUY_VESTING_DURATION, cliffDuration: DEV_BUY_CLIFF_DURATION
        });

        vm.deal(deployments.deployer, DEV_BUY_AMOUNT);
        vm.prank(deployments.deployer);
        address governance;
        address timelock;
        (asset, poolKey, governance, timelock, devBuyAmountOut) = deployments.bundler.bundle{ value: DEV_BUY_AMOUNT }(
            createData, vestingData, DEV_BUY_AMOUNT, deployments.deployer
        );

        require(asset.code.length != 0, "asset was not deployed");
        require(governance == address(0xdead) && timelock == address(0xdead), "governance was deployed");
        require(devBuyAmountOut > 0, "dev buy returned no tokens");
        require(DopplerERC20V1(asset).balanceOf(address(deployments.bundler)) == devBuyAmountOut, "dev buy not vested");
        require(DopplerERC20V1(asset).vestedTotalAmount() == TOKEN_VESTING_ALLOCATION, "token allocation mismatch");

        PoolSwapTest swapRouter = new PoolSwapTest(deployments.poolManager);
        PoolId poolId = poolKey.toId();
        _validateLaunchConfiguration(deployments, DopplerERC20V1(asset), poolId);

        _buy(swapRouter, poolKey, FOLLOW_UP_BUY_AMOUNT);
        _requireLastTax(deployments.rehype, poolId, START_TAX);

        vm.warp(block.timestamp + TAX_DECAY_DURATION / 2);
        _buy(swapRouter, poolKey, FOLLOW_UP_BUY_AMOUNT);
        _requireLastTax(deployments.rehype, poolId, 406_250); // midpoint of 80% -> 1.25%

        vm.warp(block.timestamp + TAX_DECAY_DURATION / 2 + 1);
        _buy(swapRouter, poolKey, FOLLOW_UP_BUY_AMOUNT);
        _requireLastTax(deployments.rehype, poolId, END_TAX);

        vm.warp(block.timestamp + DEV_BUY_CLIFF_DURATION);
        uint256 firstClaim = deployments.bundler.claimable(asset);
        require(firstClaim > 0 && firstClaim < devBuyAmountOut, "cliff claim is not partially vested");
        vm.prank(deployments.deployer);
        deployments.bundler.claim(asset);
        _sell(swapRouter, poolKey, DopplerERC20V1(asset), deployments.deployer, firstClaim / 2);

        vm.warp(block.timestamp + DEV_BUY_VESTING_DURATION - DEV_BUY_CLIFF_DURATION);
        uint256 finalClaim = deployments.bundler.claimable(asset);
        require(finalClaim > 0, "final vesting claim is empty");
        vm.prank(deployments.deployer);
        deployments.bundler.claim(asset);

        DopplerERC20V1 token = DopplerERC20V1(asset);
        token.releaseFor(deployments.treasury, 0);
        uint256 treasuryAtCliff = token.balanceOf(deployments.treasury);
        require(
            treasuryAtCliff > 0 && treasuryAtCliff < TOKEN_VESTING_ALLOCATION,
            "token cliff release is not partially vested"
        );

        vm.warp(token.vestingStart() + TOKEN_VESTING_DURATION + 1);
        token.releaseFor(deployments.treasury, 0);
        require(token.balanceOf(deployments.treasury) == TOKEN_VESTING_ALLOCATION, "token vesting did not complete");

        console.log("Priority launch asset:", asset);
        console.log("Dev buy tokens vested:", devBuyAmountOut);
        console.log("Final Rehype tax (millionths):", END_TAX);
    }

    function _testDeployment(
        address airlock,
        address bundler,
        address tokenFactory,
        address governanceFactory,
        address initializer,
        address rehype,
        address migrator
    ) internal returns (address asset, PoolKey memory poolKey, uint128 devBuyAmountOut) {
        uint256 chainId = block.chainid;
        Deployments memory deployments = Deployments({
            airlock: Airlock(payable(airlock)),
            bundler: Bundler(payable(bundler)),
            tokenFactory: DopplerERC20V1Factory(tokenFactory),
            governanceFactory: NoOpGovernanceFactory(governanceFactory),
            initializer: DopplerHookInitializer(payable(initializer)),
            rehype: RehypeDopplerHookInitializer(payable(rehype)),
            migrator: NoOpMigrator(migrator),
            poolManager: IPoolManager(config.get(chainId, "uniswap_v4_pool_manager").toAddress()),
            deployer: config.get(chainId, "deployer_owner").toAddress(),
            treasury: vm.envOr("TEST_DEPLOYMENT_TREASURY", DEFAULT_TREASURY)
        });
        return _testDeployment(deployments);
    }

    function _loadDeployments() internal view returns (Deployments memory deployments) {
        uint256 chainId = block.chainid;
        deployments = Deployments({
            airlock: Airlock(payable(config.get(chainId, "airlock").toAddress())),
            bundler: Bundler(payable(config.get(chainId, "bundler").toAddress())),
            tokenFactory: DopplerERC20V1Factory(config.get(chainId, "doppler_erc20_v1_factory").toAddress()),
            governanceFactory: NoOpGovernanceFactory(config.get(chainId, "no_op_governance_factory").toAddress()),
            initializer: DopplerHookInitializer(payable(config.get(chainId, "doppler_hook_initializer").toAddress())),
            rehype: RehypeDopplerHookInitializer(
                payable(config.get(chainId, "rehype_doppler_hook_initializer").toAddress())
            ),
            migrator: NoOpMigrator(config.get(chainId, "no_op_migrator").toAddress()),
            poolManager: IPoolManager(config.get(chainId, "uniswap_v4_pool_manager").toAddress()),
            deployer: config.get(chainId, "deployer_owner").toAddress(),
            treasury: vm.envOr("TEST_DEPLOYMENT_TREASURY", DEFAULT_TREASURY)
        });
    }

    function _validateDeployments(Deployments memory deployments) internal view {
        require(address(deployments.airlock).code.length != 0, "airlock is not deployed");
        require(address(deployments.bundler).code.length != 0, "bundler is not deployed");
        require(address(deployments.tokenFactory).code.length != 0, "token factory is not deployed");
        require(address(deployments.governanceFactory).code.length != 0, "governance factory is not deployed");
        require(address(deployments.initializer).code.length != 0, "initializer is not deployed");
        require(address(deployments.rehype).code.length != 0, "rehype hook is not deployed");
        require(address(deployments.migrator).code.length != 0, "migrator is not deployed");
        require(address(deployments.poolManager).code.length != 0, "pool manager is not deployed");
        require(deployments.deployer != address(0), "deployer is zero");
        require(deployments.treasury != address(0), "treasury is zero");
        require(deployments.deployer != deployments.treasury, "fee beneficiaries must be distinct");

        require(address(deployments.bundler.airlock()) == address(deployments.airlock), "bundler airlock mismatch");
        require(
            address(deployments.bundler.poolManager()) == address(deployments.poolManager), "bundler manager mismatch"
        );
        require(
            address(deployments.initializer.airlock()) == address(deployments.airlock), "initializer airlock mismatch"
        );
        require(
            address(deployments.initializer.poolManager()) == address(deployments.poolManager),
            "initializer manager mismatch"
        );
        require(deployments.rehype.INITIALIZER() == address(deployments.initializer), "rehype initializer mismatch");
        require(
            address(deployments.rehype.poolManager()) == address(deployments.poolManager), "rehype manager mismatch"
        );
        require(deployments.rehype.bundler() == address(deployments.bundler), "rehype bundler mismatch");
    }

    function _whitelist(Deployments memory deployments) internal {
        address[] memory modules = new address[](4);
        modules[0] = address(deployments.tokenFactory);
        modules[1] = address(deployments.governanceFactory);
        modules[2] = address(deployments.initializer);
        modules[3] = address(deployments.migrator);

        ModuleState[] memory states = new ModuleState[](4);
        states[0] = ModuleState.TokenFactory;
        states[1] = ModuleState.GovernanceFactory;
        states[2] = ModuleState.PoolInitializer;
        states[3] = ModuleState.LiquidityMigrator;

        address airlockOwner = deployments.airlock.owner();
        vm.startPrank(airlockOwner);
        deployments.airlock.setModuleState(modules, states);

        address[] memory hooks = new address[](1);
        hooks[0] = address(deployments.rehype);
        uint256[] memory flags = new uint256[](1);
        flags[0] = ON_INITIALIZATION_FLAG | ON_SWAP_FLAG;
        deployments.initializer.setDopplerHookState(hooks, flags);
        vm.stopPrank();

        for (uint256 i; i < modules.length; ++i) {
            require(deployments.airlock.getModuleState(modules[i]) == states[i], "module whitelist mismatch");
        }
        require(
            deployments.initializer.isDopplerHookEnabled(address(deployments.rehype))
                == ON_INITIALIZATION_FLAG | ON_SWAP_FLAG,
            "Rehype hook whitelist mismatch"
        );
    }

    function _createParams(
        Deployments memory deployments,
        bytes32 salt
    ) internal view returns (CreateParams memory createData) {
        Curve[] memory curves = new Curve[](3);
        curves[0] = Curve({ tickLower: 0, tickUpper: 240_000, numPositions: 10, shares: uint96(0.3 ether) });
        curves[1] = Curve({ tickLower: 80_000, tickUpper: 240_000, numPositions: 10, shares: uint96(0.3 ether) });
        curves[2] = Curve({ tickLower: 160_000, tickUpper: 240_000, numPositions: 10, shares: uint96(0.4 ether) });

        BeneficiaryData[] memory poolBeneficiaries = new BeneficiaryData[](1);
        poolBeneficiaries[0] = BeneficiaryData({ beneficiary: deployments.airlock.owner(), shares: uint96(WAD) });

        FeeDistributionInfo memory distribution = FeeDistributionInfo({
            assetFeesToAssetBuybackWad: 0,
            assetFeesToNumeraireBuybackWad: 0.8 ether,
            assetFeesToBeneficiaryWad: 0,
            assetFeesToLpWad: 0.2 ether,
            numeraireFeesToAssetBuybackWad: 0,
            numeraireFeesToNumeraireBuybackWad: 0.8 ether,
            numeraireFeesToBeneficiaryWad: 0,
            numeraireFeesToLpWad: 0.2 ether
        });

        RehypeInitData memory rehypeData = RehypeInitData({
            numeraire: address(0),
            buybackDst: deployments.treasury,
            startFee: START_TAX,
            endFee: END_TAX,
            durationSeconds: TAX_DECAY_DURATION,
            startingTime: 0,
            feeRoutingMode: FeeRoutingMode.RouteToBeneficiaryFees,
            feeDistributionInfo: distribution,
            feeBeneficiaries: _feeBeneficiaries(deployments.deployer, deployments.treasury)
        });

        InitData memory initData = InitData({
            fee: 0,
            tickSpacing: 8,
            farTick: 200_000,
            curves: curves,
            beneficiaries: poolBeneficiaries,
            dopplerHook: address(deployments.rehype),
            onInitializationDopplerHookCalldata: abi.encode(rehypeData),
            graduationDopplerHookCalldata: bytes("")
        });

        createData = CreateParams({
            initialSupply: INITIAL_SUPPLY,
            numTokensToSell: INITIAL_SUPPLY - TOKEN_VESTING_ALLOCATION,
            numeraire: address(0),
            tokenFactory: ITokenFactory(deployments.tokenFactory),
            tokenFactoryData: _tokenFactoryData(deployments.treasury),
            governanceFactory: IGovernanceFactory(address(deployments.governanceFactory)),
            governanceFactoryData: bytes(""),
            poolInitializer: IPoolInitializer(address(deployments.initializer)),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(address(deployments.migrator)),
            liquidityMigratorData: bytes(""),
            integrator: address(0),
            salt: salt
        });
    }

    function _tokenFactoryData(address treasury) internal pure returns (bytes memory) {
        VestingSchedule[] memory schedules = new VestingSchedule[](1);
        schedules[0] = VestingSchedule({ cliff: TOKEN_VESTING_CLIFF, duration: TOKEN_VESTING_DURATION });

        address[] memory beneficiaries = new address[](1);
        beneficiaries[0] = treasury;
        uint256[] memory scheduleIds = new uint256[](1);
        scheduleIds[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = TOKEN_VESTING_ALLOCATION;

        return abi.encode(
            "Doppler Launch Test",
            "DLTEST",
            schedules,
            beneficiaries,
            scheduleIds,
            amounts,
            "ipfs://test-deployment",
            uint256(0),
            uint48(0),
            address(0),
            new address[](0)
        );
    }

    function _feeBeneficiaries(
        address deployer,
        address treasury
    ) internal pure returns (BeneficiaryData[] memory beneficiaries) {
        beneficiaries = new BeneficiaryData[](2);
        address first = deployer < treasury ? deployer : treasury;
        address second = deployer < treasury ? treasury : deployer;
        beneficiaries[0] = BeneficiaryData({ beneficiary: first, shares: uint96(WAD / 2) });
        beneficiaries[1] = BeneficiaryData({ beneficiary: second, shares: uint96(WAD / 2) });
    }

    function _buy(PoolSwapTest router, PoolKey memory key, uint128 amountIn) internal returns (uint256 amountOut) {
        bool zeroForOne = key.currency0 == Currency.wrap(address(0));
        vm.deal(TRADER, TRADER.balance + amountIn);
        vm.prank(TRADER);
        BalanceDelta delta = router.swap{ value: amountIn }(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        amountOut = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        require(amountOut > 0, "buy returned no tokens");
    }

    function _sell(
        PoolSwapTest router,
        PoolKey memory key,
        DopplerERC20V1 asset,
        address seller,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        require(amountIn > 0, "sell amount is zero");
        bool zeroForOne = key.currency0 == Currency.wrap(address(asset));

        vm.prank(seller);
        asset.approve(address(router), amountIn);
        vm.prank(seller);
        BalanceDelta delta = router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        amountOut = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        require(amountOut > 0, "sell returned no ETH");
    }

    function _validateLaunchConfiguration(
        Deployments memory deployments,
        DopplerERC20V1 token,
        PoolId poolId
    ) internal view {
        require(
            deployments.initializer.getShares(poolId, deployments.airlock.owner()) == WAD,
            "pool earnings are not owned by Airlock owner"
        );
        require(deployments.rehype.getShares(poolId, deployments.deployer) == WAD / 2, "deployer fee share mismatch");
        require(deployments.rehype.getShares(poolId, deployments.treasury) == WAD / 2, "treasury fee share mismatch");
        require(
            deployments.rehype.getFeeRoutingMode(poolId) == FeeRoutingMode.RouteToBeneficiaryFees,
            "fee routing mode mismatch"
        );

        (
            ,
            uint256 assetFeesToNumeraire,,
            uint256 assetFeesToLp,,
            uint256 numeraireFeesToNumeraire,,
            uint256 numeraireFeesToLp
        ) = deployments.rehype.getFeeDistributionInfo(poolId);
        require(assetFeesToNumeraire == 0.8 ether && numeraireFeesToNumeraire == 0.8 ether, "ETH fee share mismatch");
        require(assetFeesToLp == 0.2 ether && numeraireFeesToLp == 0.2 ether, "LP fee share mismatch");

        (uint64 cliff, uint64 duration) = token.vestingSchedules(0);
        require(cliff == TOKEN_VESTING_CLIFF && duration == TOKEN_VESTING_DURATION, "token vesting mismatch");
        (uint256 totalAmount, uint256 releasedAmount) = token.vestingOf(deployments.treasury, 0);
        require(totalAmount == TOKEN_VESTING_ALLOCATION && releasedAmount == 0, "token allocation mismatch");
    }

    function _requireLastTax(RehypeDopplerHookInitializer rehype, PoolId poolId, uint24 expected) internal view {
        (,,, uint24 lastFee,) = rehype.getFeeSchedule(poolId);
        require(lastFee == expected, "unexpected Rehype tax");
    }
}

/// @notice Standalone entrypoint for testing deployments already recorded in deployments.config.toml.
contract TestDeploymentScript is TestDeployment {
    function run() external returns (address asset, PoolKey memory poolKey, uint128 devBuyAmountOut) {
        _loadConfigForCurrentChain();
        if (_shouldWriteConfig()) revert BroadcastForbidden();
        return _testDeployment(_loadDeployments());
    }
}
