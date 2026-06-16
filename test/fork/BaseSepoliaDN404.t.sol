// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import { DopplerHookInitializer, InitData, PoolStatus } from "src/initializers/DopplerHookInitializer.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { Curve } from "src/libraries/Multicurve.sol";
import { DN404Factory } from "src/tokens/DN404Factory.sol";
import { DopplerDN404 } from "src/tokens/DopplerDN404.sol";
import { DopplerDN404Mirror } from "src/tokens/DopplerDN404Mirror.sol";
import { BeneficiaryData } from "src/types/BeneficiaryData.sol";
import { WAD } from "src/types/Wad.sol";

contract BaseSepoliaDN404ForkTest is Test {
    address internal constant AIRLOCK = 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e;
    address internal constant DEFAULT_DN404_FACTORY = 0x98b0Aa2e0f134dbB3eb157b5646D387E6D55243a;
    address internal constant DOPPLER_HOOK_INITIALIZER = 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544;
    address internal constant NO_OP_GOVERNANCE_FACTORY = 0x7bD798fafC99A3b17E261F8308A8C11B56935ea1;
    address internal constant NO_OP_MIGRATOR = 0xF11066abbd329ac4bBA39455340539322C222eb0;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    string internal constant NAME = "Fork DN404";
    string internal constant SYMBOL = "FDN404";
    string internal constant BASE_URI = "ipfs://fork-dn404/";

    Airlock internal airlock = Airlock(payable(AIRLOCK));
    address internal dn404FactoryAddress;
    DN404Factory internal dn404Factory;
    DopplerHookInitializer internal dopplerHookInitializer = DopplerHookInitializer(payable(DOPPLER_HOOK_INITIALIZER));

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC_URL"));
        dn404FactoryAddress = vm.envOr("BASE_SEPOLIA_DN404_FACTORY", DEFAULT_DN404_FACTORY);
        dn404Factory = DN404Factory(dn404FactoryAddress);

        assertEq(block.chainid, 84_532);
        assertEq(address(dn404Factory.airlock()), AIRLOCK);
        assertEq(uint256(airlock.getModuleState(dn404FactoryAddress)), uint256(ModuleState.TokenFactory));
        assertEq(uint256(airlock.getModuleState(DOPPLER_HOOK_INITIALIZER)), uint256(ModuleState.PoolInitializer));
        assertEq(uint256(airlock.getModuleState(NO_OP_GOVERNANCE_FACTORY)), uint256(ModuleState.GovernanceFactory));
        assertEq(uint256(airlock.getModuleState(NO_OP_MIGRATOR)), uint256(ModuleState.LiquidityMigrator));
    }

    function test_deploysDN404ThroughDopplerHookInitializer() public {
        uint256 initialSupply = 1e27;
        uint256 unit = initialSupply;
        bytes32 salt = keccak256("base-sepolia-dn404-doppler-hook-initializer");
        InitData memory initData = _dopplerHookInitData();

        (address asset, address pool, address governance, address timelock, address migrationPool) =
            airlock.create(_createParams(salt, initialSupply, unit, abi.encode(initData)));

        assertGt(asset.code.length, 0);
        assertEq(pool, asset);
        assertEq(governance, address(0xdead));
        assertEq(timelock, address(0xdead));
        assertEq(migrationPool, 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD);
        _assertDN404(asset, migrationPool, initialSupply, unit);
        _assertDopplerHookState(asset, initialSupply);
    }

    function _assertDN404(address asset, address migrationPool, uint256 initialSupply, uint256 unit) internal view {
        DopplerDN404 token = DopplerDN404(payable(asset));
        address mirror = token.mirrorERC721();

        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.totalSupply(), initialSupply);
        assertEq(token.owner(), AIRLOCK);
        assertEq(token.unit(), unit);
        assertEq(token.baseURI(), BASE_URI);
        assertEq(token.pool(), migrationPool);
        assertFalse(token.isPoolUnlocked());
        assertEq(DopplerDN404Mirror(payable(mirror)).baseERC20(), asset);
    }

    function _assertDopplerHookState(address asset, uint256 initialSupply) internal view {
        (
            address numeraire,
            uint256 totalTokensOnBondingCurve,
            address dopplerHook,,
            PoolStatus status,
            PoolKey memory poolKey,
            int24 farTick
        ) = dopplerHookInitializer.getState(asset);

        assertEq(numeraire, WETH);
        assertEq(totalTokensOnBondingCurve, initialSupply);
        assertEq(dopplerHook, address(0));
        assertEq(uint8(status), uint8(PoolStatus.Initialized));
        assertEq(address(poolKey.hooks), DOPPLER_HOOK_INITIALIZER);
        assertEq(poolKey.fee, 0);
        assertEq(poolKey.tickSpacing, 8);
        assertEq(farTick, asset < WETH ? int24(200_000) : -int24(200_000));
        assertTrue(Currency.unwrap(poolKey.currency0) == asset || Currency.unwrap(poolKey.currency1) == asset);
        assertTrue(Currency.unwrap(poolKey.currency0) == WETH || Currency.unwrap(poolKey.currency1) == WETH);
    }

    function _createParams(
        bytes32 salt,
        uint256 initialSupply,
        uint256 unit,
        bytes memory poolInitializerData
    ) internal view returns (CreateParams memory) {
        return CreateParams({
            initialSupply: initialSupply,
            numTokensToSell: initialSupply,
            numeraire: WETH,
            tokenFactory: ITokenFactory(dn404FactoryAddress),
            tokenFactoryData: abi.encode(NAME, SYMBOL, BASE_URI, unit),
            governanceFactory: IGovernanceFactory(NO_OP_GOVERNANCE_FACTORY),
            governanceFactoryData: new bytes(0),
            poolInitializer: IPoolInitializer(DOPPLER_HOOK_INITIALIZER),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(NO_OP_MIGRATOR),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });
    }

    function _dopplerHookInitData() internal pure returns (InitData memory) {
        return InitData({
            fee: 0,
            tickSpacing: 8,
            farTick: 200_000,
            curves: _curves(),
            beneficiaries: new BeneficiaryData[](0),
            dopplerHook: address(0),
            onInitializationDopplerHookCalldata: new bytes(0),
            graduationDopplerHookCalldata: new bytes(0)
        });
    }

    function _curves() internal pure returns (Curve[] memory curves) {
        curves = new Curve[](10);
        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }
    }
}
