// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import {
    Bundler,
    InvalidVestingSchedule,
    NoClaimableAmount,
    SenderNotRecipient,
    VestingCreated,
    VestingReleased
} from "src/Bundler.sol";
import { ON_INITIALIZATION_FLAG, ON_SWAP_FLAG } from "src/base/BaseDopplerHookInitializer.sol";
import { RehypeDopplerHookInitializer } from "src/dopplerHooks/RehypeDopplerHookInitializer.sol";
import { GovernanceFactory } from "src/governance/GovernanceFactory.sol";
import { DopplerHookInitializer, InitData } from "src/initializers/DopplerHookInitializer.sol";
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

contract BundlerVestingLiquidityMigratorMock is ILiquidityMigrator {
    function initialize(address, address, bytes calldata) external pure returns (address) {
        return address(0xdeadbeef);
    }

    function migrate(uint160, address, address, address) external payable returns (uint256) {
        return 0;
    }
}

contract BundlerVestingIntegrationTest is Deployers {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant START_FEE = 800_000;
    uint128 internal constant DEV_BUY_AMOUNT = 1 ether;
    uint256 internal constant INITIAL_SUPPLY = 1e27;
    uint64 internal constant VESTING_DURATION = 100 days;
    uint64 internal constant CLIFF_DURATION = 20 days;

    address internal airlockOwner = makeAddr("vestingAirlockOwner");
    address internal buybackDst = makeAddr("vestingBuybackDst");
    address internal payer = makeAddr("vestingPayer");
    address internal recipient = makeAddr("vestingRecipient");
    address internal attacker = makeAddr("vestingAttacker");

    Airlock internal airlock;
    Bundler internal bundler;
    DopplerHookInitializer internal initializer;
    DopplerERC20V1Factory internal tokenFactory;
    GovernanceFactory internal governanceFactory;
    BundlerVestingLiquidityMigratorMock internal liquidityMigrator;
    RehypeDopplerHookInitializer internal rehype;
    TestERC20 internal erc20Numeraire;

    address internal vestedAsset;
    PoolKey internal vestedPoolKey;
    uint128 internal vestedAmountOut;
    address internal quotedAsset;
    uint128 internal quotedAmountOut;

    function setUp() public {
        deployFreshManagerAndRouters();

        airlock = new Airlock(airlockOwner);
        tokenFactory = new DopplerERC20V1Factory(address(airlock));
        governanceFactory = new GovernanceFactory(address(airlock));
        liquidityMigrator = new BundlerVestingLiquidityMigratorMock();
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

    function test_bundle_ZeroVestingDurationTransfersDirectlyAndStoresNoPosition() public {
        this.bundleERC20(bytes32(uint256(1)), true, 0, 0);

        assertEq(TestERC20(vestedAsset).balanceOf(recipient), vestedAmountOut);
        assertEq(TestERC20(vestedAsset).balanceOf(address(bundler)), 0);
        assertEq(bundler.claimable(vestedAsset), 0);
        _assertVestingAmounts(vestedAsset, 0, 0);
    }

    function test_bundle_VestingCustodiesOutputStoresScheduleAndMatchesSimulation() public {
        bytes32 salt = bytes32(uint256(2));
        this.simulateERC20(salt);

        assertEq(quotedAsset.code.length, 0, "simulation must revert asset deployment");
        assertEq(bundler.claimable(quotedAsset), 0, "simulation must not create vesting state");

        uint64 expectedStart = uint64(block.timestamp);
        vm.expectEmit(true, true, false, true, address(bundler));
        emit VestingCreated(
            quotedAsset, recipient, true, quotedAmountOut, expectedStart, CLIFF_DURATION, VESTING_DURATION
        );
        this.bundleERC20(salt, true, VESTING_DURATION, CLIFF_DURATION);

        assertEq(vestedAsset, quotedAsset);
        assertEq(vestedAmountOut, quotedAmountOut);
        assertEq(TestERC20(vestedAsset).balanceOf(recipient), 0);
        assertEq(TestERC20(vestedAsset).balanceOf(address(bundler)), vestedAmountOut);
        assertEq(bundler.claimable(vestedAsset), 0);
        _assertVestingConfig(vestedAsset, true, expectedStart, CLIFF_DURATION, VESTING_DURATION);
        _assertVestingAmounts(vestedAsset, vestedAmountOut, 0);
        _assertOwnerOnlyDevBuyFee(vestedPoolKey.toId(), vestedPoolKey, vestedAmountOut);
    }

    function test_claim_PermissionlessClaimAccruesContinuouslyAndReleasesRemainderAtEnd() public {
        this.bundleERC20(bytes32(uint256(3)), true, VESTING_DURATION, CLIFF_DURATION);
        (,, uint64 start,,,,) = bundler.vestingOf(vestedAsset);

        vm.warp(uint256(start) + CLIFF_DURATION - 1);
        assertEq(bundler.claimable(vestedAsset), 0);
        vm.prank(attacker);
        vm.expectRevert(NoClaimableAmount.selector);
        bundler.claim(vestedAsset);

        vm.warp(uint256(start) + CLIFF_DURATION);
        uint256 expectedAtCliff = uint256(vestedAmountOut) * CLIFF_DURATION / VESTING_DURATION;
        assertEq(bundler.claimable(vestedAsset), expectedAtCliff);

        vm.expectEmit(true, true, false, true, address(bundler));
        emit VestingReleased(vestedAsset, recipient, uint128(expectedAtCliff));
        vm.prank(attacker);
        assertEq(bundler.claim(vestedAsset), expectedAtCliff);
        assertEq(TestERC20(vestedAsset).balanceOf(recipient), expectedAtCliff);

        vm.prank(attacker);
        vm.expectRevert(NoClaimableAmount.selector);
        bundler.claim(vestedAsset);

        uint256 midpointElapsed = (uint256(CLIFF_DURATION) + VESTING_DURATION) / 2;
        vm.warp(uint256(start) + midpointElapsed);
        uint256 expectedAtMidpoint = uint256(vestedAmountOut) * midpointElapsed / VESTING_DURATION;
        uint256 midpointClaim = expectedAtMidpoint - expectedAtCliff;
        assertEq(bundler.claimable(vestedAsset), midpointClaim);

        vm.prank(attacker);
        assertEq(bundler.claim(vestedAsset), midpointClaim);
        assertEq(TestERC20(vestedAsset).balanceOf(recipient), expectedAtMidpoint);
        _assertVestingAmounts(vestedAsset, vestedAmountOut, uint128(expectedAtMidpoint));

        vm.warp(uint256(start) + VESTING_DURATION);
        uint256 remainder = uint256(vestedAmountOut) - expectedAtMidpoint;
        assertEq(bundler.claimable(vestedAsset), remainder);
        vm.prank(attacker);
        assertEq(bundler.claim(vestedAsset), remainder);

        assertEq(TestERC20(vestedAsset).balanceOf(recipient), vestedAmountOut);
        assertEq(TestERC20(vestedAsset).balanceOf(address(bundler)), 0);
        assertEq(bundler.claimable(vestedAsset), 0);
        _assertVestingAmounts(vestedAsset, vestedAmountOut, vestedAmountOut);
    }

    function test_claim_RestrictedClaimRequiresRecipientAndCliffMayEqualDuration() public {
        uint64 duration = 2 days;
        this.bundleERC20(bytes32(uint256(4)), false, duration, duration);
        (,, uint64 start,,,,) = bundler.vestingOf(vestedAsset);

        vm.warp(uint256(start) + duration - 1);
        assertEq(bundler.claimable(vestedAsset), 0);

        vm.warp(uint256(start) + duration);
        assertEq(bundler.claimable(vestedAsset), vestedAmountOut);
        vm.prank(attacker);
        vm.expectRevert(SenderNotRecipient.selector);
        bundler.claim(vestedAsset);

        vm.prank(recipient);
        assertEq(bundler.claim(vestedAsset), vestedAmountOut);
        assertEq(TestERC20(vestedAsset).balanceOf(recipient), vestedAmountOut);
    }

    function test_claim_OneDayMinimumVestingWithNoCliff() public {
        this.bundleERC20(bytes32(uint256(5)), true, 1 days, 0);
        (,, uint64 start,,,,) = bundler.vestingOf(vestedAsset);

        assertEq(bundler.claimable(vestedAsset), 0);
        vm.warp(uint256(start) + 1 days);
        assertEq(bundler.claimable(vestedAsset), vestedAmountOut);

        vm.prank(attacker);
        assertEq(bundler.claim(vestedAsset), vestedAmountOut);
    }

    function test_bundle_NativeNumeraireVestingCustodiesOutput() public {
        CreateParams memory params = this.createParams(address(0), bytes32(uint256(6)));

        vm.deal(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        (address asset, PoolKey memory poolKey,,, uint128 amountOut) = bundler.bundle{ value: DEV_BUY_AMOUNT }(
            params, _vestingParams(false, VESTING_DURATION, CLIFF_DURATION), DEV_BUY_AMOUNT, recipient
        );

        assertEq(TestERC20(asset).balanceOf(recipient), 0);
        assertEq(TestERC20(asset).balanceOf(address(bundler)), amountOut);
        assertEq(payer.balance, 0);
        assertEq(address(bundler).balance, 0);
        _assertOwnerOnlyDevBuyFee(poolKey.toId(), poolKey, amountOut);
    }

    function test_bundle_RevertsWhenVestingDurationIsBelowOneDay() public {
        CreateParams memory params = this.createParams(address(erc20Numeraire), bytes32(uint256(7)));

        vm.expectRevert(InvalidVestingSchedule.selector);
        bundler.bundle(params, _vestingParams(true, 1 days - 1, 0), DEV_BUY_AMOUNT, recipient);
    }

    function test_bundle_RevertsWhenCliffExceedsVestingDuration() public {
        CreateParams memory params = this.createParams(address(erc20Numeraire), bytes32(uint256(7)));

        vm.expectRevert(InvalidVestingSchedule.selector);
        bundler.bundle(params, _vestingParams(true, 1 days, 1 days + 1), DEV_BUY_AMOUNT, recipient);
    }

    function test_bundle_RevertsWhenZeroDurationHasNonzeroCliff() public {
        CreateParams memory params = this.createParams(address(erc20Numeraire), bytes32(uint256(8)));

        vm.expectRevert(InvalidVestingSchedule.selector);
        bundler.bundle(params, _vestingParams(true, 0, 1), DEV_BUY_AMOUNT, recipient);
    }

    function test_claim_UnknownAssetReverts() public {
        assertEq(bundler.claimable(address(0xbeef)), 0);
        vm.expectRevert(NoClaimableAmount.selector);
        bundler.claim(address(0xbeef));
    }

    function bundleERC20(
        bytes32 salt,
        bool permissionlessClaim,
        uint64 vestingDuration,
        uint64 cliffDuration
    ) external {
        CreateParams memory params = this.createParams(address(erc20Numeraire), salt);
        erc20Numeraire.transfer(payer, DEV_BUY_AMOUNT);
        vm.prank(payer);
        erc20Numeraire.approve(address(bundler), DEV_BUY_AMOUNT);

        vm.prank(payer);
        (vestedAsset, vestedPoolKey,,, vestedAmountOut) = bundler.bundle(
            params, _vestingParams(permissionlessClaim, vestingDuration, cliffDuration), DEV_BUY_AMOUNT, recipient
        );
    }

    function _vestingParams(
        bool permissionlessClaim,
        uint64 vestingDuration,
        uint64 cliffDuration
    ) internal pure returns (Bundler.VestingParams memory) {
        return Bundler.VestingParams({
            permissionlessClaim: permissionlessClaim, vestingDuration: vestingDuration, cliffDuration: cliffDuration
        });
    }

    function simulateERC20(bytes32 salt) external {
        CreateParams memory params = this.createParams(address(erc20Numeraire), salt);
        vm.prank(payer);
        (quotedAsset,,,, quotedAmountOut) = bundler.simulateBundle(params, DEV_BUY_AMOUNT);
    }

    function _assertVestingConfig(
        address asset,
        bool expectedPermissionlessClaim,
        uint64 expectedStart,
        uint64 expectedCliffDuration,
        uint64 expectedVestingDuration
    ) internal view {
        (
            address storedRecipient,
            bool permissionlessClaim,
            uint64 start,
            uint64 cliffDuration,
            uint64 vestingDuration,,
        ) = bundler.vestingOf(asset);

        assertEq(storedRecipient, recipient);
        assertEq(permissionlessClaim, expectedPermissionlessClaim);
        assertEq(start, expectedStart);
        assertEq(cliffDuration, expectedCliffDuration);
        assertEq(vestingDuration, expectedVestingDuration);
    }

    function _assertVestingAmounts(
        address asset,
        uint128 expectedTotalAmount,
        uint128 expectedClaimedAmount
    ) internal view {
        (,,,,, uint128 totalAmount, uint128 claimedAmount) = bundler.vestingOf(asset);
        assertEq(totalAmount, expectedTotalAmount);
        assertEq(claimedAmount, expectedClaimedAmount);
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

    function createParams(address numeraire, bytes32 salt) external view returns (CreateParams memory params) {
        (params,) = _createParams(numeraire, salt);
    }

    function _createParams(
        address numeraire,
        bytes32 salt
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
            startFee: START_FEE,
            endFee: START_FEE,
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
                "Bundler Vesting Test", "BVEST", "TOKEN_URI", 0, 0, address(0), new address[](0)
            ),
            governanceFactory: IGovernanceFactory(governanceFactory),
            governanceFactoryData: abi.encode("Bundler Vesting Test", uint48(7200), uint32(50_400), uint256(0)),
            poolInitializer: IPoolInitializer(initializer),
            poolInitializerData: abi.encode(initData),
            liquidityMigrator: ILiquidityMigrator(liquidityMigrator),
            liquidityMigratorData: bytes(""),
            integrator: address(0),
            salt: salt
        });
    }
}
