// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { Airlock, CreateParams, ModuleState } from "src/Airlock.sol";
import {
    InitData as MulticurveInitData,
    PoolStatus,
    UniswapV4MulticurveInitializer
} from "src/initializers/UniswapV4MulticurveInitializer.sol";
import {
    InitData as ScheduledMulticurveInitData,
    UniswapV4ScheduledMulticurveInitializer
} from "src/initializers/UniswapV4ScheduledMulticurveInitializer.sol";
import {
    UniswapV4ScheduledMulticurveInitializerHook
} from "src/initializers/UniswapV4ScheduledMulticurveInitializerHook.sol";
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
    using PoolIdLibrary for PoolKey;

    address internal constant AIRLOCK = 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e;
    address internal constant DEFAULT_DN404_FACTORY = 0x98b0Aa2e0f134dbB3eb157b5646D387E6D55243a;
    address internal constant MULTICURVE_INITIALIZER = 0x1718405E58c61425cDc0083262bC9f72198F5232;
    address internal constant SCHEDULED_MULTICURVE_INITIALIZER = 0xF84378C9F39e0FF267f3101c88773359c5393876;
    address internal constant NO_OP_GOVERNANCE_FACTORY = 0x7bD798fafC99A3b17E261F8308A8C11B56935ea1;
    address internal constant NO_OP_MIGRATOR = 0xF11066abbd329ac4bBA39455340539322C222eb0;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    string internal constant NAME = "Fork DN404";
    string internal constant SYMBOL = "FDN404";
    string internal constant BASE_URI = "ipfs://fork-dn404/";

    Airlock internal airlock = Airlock(payable(AIRLOCK));
    address internal dn404FactoryAddress;
    DN404Factory internal dn404Factory;
    UniswapV4MulticurveInitializer internal multicurveInitializer =
        UniswapV4MulticurveInitializer(payable(MULTICURVE_INITIALIZER));
    UniswapV4ScheduledMulticurveInitializer internal scheduledMulticurveInitializer =
        UniswapV4ScheduledMulticurveInitializer(payable(SCHEDULED_MULTICURVE_INITIALIZER));

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC_URL"));
        dn404FactoryAddress = vm.envOr("BASE_SEPOLIA_DN404_FACTORY", DEFAULT_DN404_FACTORY);
        dn404Factory = DN404Factory(dn404FactoryAddress);

        assertEq(block.chainid, 84_532);
        assertEq(address(dn404Factory.airlock()), AIRLOCK);
        assertEq(uint256(airlock.getModuleState(dn404FactoryAddress)), uint256(ModuleState.TokenFactory));
        assertEq(uint256(airlock.getModuleState(MULTICURVE_INITIALIZER)), uint256(ModuleState.PoolInitializer));
        assertEq(
            uint256(airlock.getModuleState(SCHEDULED_MULTICURVE_INITIALIZER)), uint256(ModuleState.PoolInitializer)
        );
        assertEq(uint256(airlock.getModuleState(NO_OP_GOVERNANCE_FACTORY)), uint256(ModuleState.GovernanceFactory));
        assertEq(uint256(airlock.getModuleState(NO_OP_MIGRATOR)), uint256(ModuleState.LiquidityMigrator));
    }

    function test_deploysDN404ThroughMulticurve() public {
        uint256 initialSupply = 1e27;
        uint256 unit = initialSupply;
        bytes32 salt = keccak256("base-sepolia-dn404-multicurve");
        MulticurveInitData memory initData = _multicurveInitData();

        (address asset, address pool, address governance, address timelock, address migrationPool) =
            airlock.create(_createParams(salt, initialSupply, unit, MULTICURVE_INITIALIZER, abi.encode(initData)));

        assertGt(asset.code.length, 0);
        assertEq(pool, asset);
        assertEq(governance, address(0xdead));
        assertEq(timelock, address(0xdead));
        assertEq(migrationPool, 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD);
        _assertDN404(asset, initialSupply, unit);

        (, PoolStatus status, PoolKey memory poolKey,) = multicurveInitializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));
        assertEq(address(poolKey.hooks), address(multicurveInitializer.HOOK()));
    }

    function test_deploysDN404ThroughScheduledMulticurve() public {
        uint256 initialSupply = 1e27;
        uint256 unit = initialSupply;
        uint32 startingTime = uint32(block.timestamp + 1 hours);
        bytes32 salt = keccak256("base-sepolia-dn404-scheduled-multicurve");
        ScheduledMulticurveInitData memory initData = _scheduledMulticurveInitData(startingTime);

        (address asset, address pool,,,) = airlock.create(
            _createParams(salt, initialSupply, unit, SCHEDULED_MULTICURVE_INITIALIZER, abi.encode(initData))
        );

        assertGt(asset.code.length, 0);
        assertEq(pool, asset);
        _assertDN404(asset, initialSupply, unit);

        (, PoolStatus status, PoolKey memory poolKey,) = scheduledMulticurveInitializer.getState(asset);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));
        assertEq(address(poolKey.hooks), address(scheduledMulticurveInitializer.HOOK()));

        PoolId poolId = poolKey.toId();
        IHooks hook = scheduledMulticurveInitializer.HOOK();
        assertEq(UniswapV4ScheduledMulticurveInitializerHook(address(hook)).startingTimeOf(poolId), startingTime);
    }

    function _assertDN404(address asset, uint256 initialSupply, uint256 unit) internal view {
        DopplerDN404 token = DopplerDN404(payable(asset));
        address mirror = token.mirrorERC721();

        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.totalSupply(), initialSupply);
        assertEq(token.owner(), AIRLOCK);
        assertEq(token.unit(), unit);
        assertEq(token.baseURI(), BASE_URI);
        assertEq(DopplerDN404Mirror(payable(mirror)).baseERC20(), asset);
    }

    function _createParams(
        bytes32 salt,
        uint256 initialSupply,
        uint256 unit,
        address poolInitializer,
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
            poolInitializer: IPoolInitializer(poolInitializer),
            poolInitializerData: poolInitializerData,
            liquidityMigrator: ILiquidityMigrator(NO_OP_MIGRATOR),
            liquidityMigratorData: new bytes(0),
            integrator: address(0),
            salt: salt
        });
    }

    function _multicurveInitData() internal pure returns (MulticurveInitData memory) {
        return
            MulticurveInitData({ fee: 0, tickSpacing: 8, curves: _curves(), beneficiaries: new BeneficiaryData[](0) });
    }

    function _scheduledMulticurveInitData(uint32 startingTime)
        internal
        pure
        returns (ScheduledMulticurveInitData memory)
    {
        return ScheduledMulticurveInitData({
            fee: 0,
            tickSpacing: 8,
            curves: _curves(),
            beneficiaries: new BeneficiaryData[](0),
            startingTime: startingTime
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
