// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { Bundler } from "src/Bundler.sol";
import { Airlock, CreateParams } from "src/Airlock.sol";
import { ITokenFactory } from "src/TokenFactory.sol";
import { IGovernanceFactory } from "src/interfaces/IGovernanceFactory.sol";
import { IPoolInitializer } from "src/interfaces/IPoolInitializer.sol";
import { ILiquidityMigrator } from "src/interfaces/ILiquidityMigrator.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IV4Quoter } from "@v4-periphery/interfaces/IV4Quoter.sol";
import { PoolStatus } from "src/UniswapV4MulticurveInitializer.sol";
import { UniversalRouter } from "@universal-router/UniversalRouter.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";

contract BundlerMulticurveTest is Test {
    Bundler bundler;
    MockAirlock mockAirlock;
    MockUniversalRouter mockRouter;
    MockQuoter mockQuoter;
    MockMulticurveInitializer mockInitializer;
    MockV4Quoter mockV4Quoter;

    function setUp() public {
        mockAirlock = new MockAirlock();
        mockRouter = new MockUniversalRouter();
        mockQuoter = new MockQuoter();
        mockV4Quoter = new MockV4Quoter();
        bundler = new Bundler(
            Airlock(payable(address(mockAirlock))),
            UniversalRouter(payable(address(mockRouter))),
            IQuoterV2(address(mockQuoter)),
            IV4Quoter(address(mockV4Quoter))
        );
        mockInitializer = new MockMulticurveInitializer();
    }

    function test_simulateMulticurveBundleExactOut() public {
        address expectedAsset = address(0x1111);
        address expectedNumeraire = address(0x2222);
        mockAirlock.setAsset(expectedAsset);

        PoolKey memory expectedKey = PoolKey({
            currency0: Currency.wrap(expectedAsset),
            currency1: Currency.wrap(expectedNumeraire),
            hooks: IHooks(address(0x3333)),
            fee: 500,
            tickSpacing: 60
        });
        mockInitializer.setPoolKey(expectedKey);

        CreateParams memory createParams = CreateParams({
            initialSupply: 1,
            numTokensToSell: 1,
            numeraire: expectedNumeraire,
            tokenFactory: ITokenFactory(address(0x1)),
            tokenFactoryData: new bytes(0),
            governanceFactory: IGovernanceFactory(address(0x2)),
            governanceFactoryData: new bytes(0),
            poolInitializer: IPoolInitializer(address(mockInitializer)),
            poolInitializerData: new bytes(0),
            liquidityMigrator: ILiquidityMigrator(address(0x3)),
            liquidityMigratorData: new bytes(0),
            integrator: address(0x4),
            salt: bytes32(uint256(0x1234))
        });

        mockV4Quoter.setExactOutResponse(321, 654);

        (address asset, PoolKey memory poolKey, uint256 amountIn, uint256 gasEstimate) =
            bundler.simulateMulticurveBundleExactOut(createParams, 1, bytes(""));

        assertEq(asset, expectedAsset, "wrong asset");
        assertEq(Currency.unwrap(poolKey.currency0), Currency.unwrap(expectedKey.currency0), "wrong currency0");
        assertEq(Currency.unwrap(poolKey.currency1), Currency.unwrap(expectedKey.currency1), "wrong currency1");
        assertEq(address(poolKey.hooks), address(expectedKey.hooks), "wrong hooks");
        assertEq(poolKey.fee, expectedKey.fee, "wrong fee");
        assertEq(poolKey.tickSpacing, expectedKey.tickSpacing, "wrong tick spacing");
        assertEq(amountIn, 321, "wrong amountIn");
        assertEq(gasEstimate, 654, "wrong gas estimate");
        assertTrue(mockV4Quoter.lastWasExactOut(), "wrong quote type");
        assertEq(mockV4Quoter.lastZeroForOne(), false, "wrong direction");
        assertEq(mockV4Quoter.lastExactAmount(), 1, "wrong exact amount");
        assertEq(mockV4Quoter.lastHookDataLength(), 0, "hook data should be empty");

        PoolKey memory recorded = mockV4Quoter.lastPoolKey();
        assertEq(Currency.unwrap(recorded.currency0), Currency.unwrap(expectedKey.currency0), "recorded currency0");
        assertEq(Currency.unwrap(recorded.currency1), Currency.unwrap(expectedKey.currency1), "recorded currency1");
        assertEq(address(recorded.hooks), address(expectedKey.hooks), "recorded hooks");
        assertEq(recorded.fee, expectedKey.fee, "recorded fee");
        assertEq(recorded.tickSpacing, expectedKey.tickSpacing, "recorded tick spacing");
    }

    function test_simulateMulticurveBundleExactIn() public {
        address expectedAsset = address(0x1111);
        address expectedNumeraire = address(0x2222);
        mockAirlock.setAsset(expectedAsset);

        PoolKey memory expectedKey = PoolKey({
            currency0: Currency.wrap(expectedAsset),
            currency1: Currency.wrap(expectedNumeraire),
            hooks: IHooks(address(0x3333)),
            fee: 500,
            tickSpacing: 60
        });
        mockInitializer.setPoolKey(expectedKey);

        CreateParams memory createParams = CreateParams({
            initialSupply: 1,
            numTokensToSell: 1,
            numeraire: expectedNumeraire,
            tokenFactory: ITokenFactory(address(0x1)),
            tokenFactoryData: new bytes(0),
            governanceFactory: IGovernanceFactory(address(0x2)),
            governanceFactoryData: new bytes(0),
            poolInitializer: IPoolInitializer(address(mockInitializer)),
            poolInitializerData: new bytes(0),
            liquidityMigrator: ILiquidityMigrator(address(0x3)),
            liquidityMigratorData: new bytes(0),
            integrator: address(0x4),
            salt: bytes32(uint256(0x5678))
        });

        mockV4Quoter.setExactInResponse(123, 999);
        bytes memory hookData = bytes("hook");

        (address asset, PoolKey memory poolKey, uint256 amountOut, uint256 gasEstimate) =
            bundler.simulateMulticurveBundleExactIn(createParams, 5, hookData);

        assertEq(asset, expectedAsset, "wrong asset");
        assertEq(Currency.unwrap(poolKey.currency0), Currency.unwrap(expectedKey.currency0), "wrong currency0");
        assertEq(Currency.unwrap(poolKey.currency1), Currency.unwrap(expectedKey.currency1), "wrong currency1");
        assertTrue(mockV4Quoter.lastWasExactIn(), "wrong quote type");
        assertEq(amountOut, 123, "wrong amountOut");
        assertEq(gasEstimate, 999, "wrong gas estimate");
        assertEq(mockV4Quoter.lastExactAmount(), 5, "wrong exact amount");
        assertEq(keccak256(mockV4Quoter.lastHookData()), keccak256(hookData), "wrong hook data");
    }
}

contract MockAirlock {
    address internal asset;

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function create(
        CreateParams calldata
    ) external view returns (address asset_, address, address, address, address) {
        asset_ = asset;
        return (asset_, address(0), address(0), address(0), address(0));
    }
}

contract MockUniversalRouter { }

contract MockQuoter { }

contract MockV4Quoter {
    enum QuoteType { None, ExactOut, ExactIn }

    PoolKey internal storedPoolKey;
    bool internal storedZeroForOne;
    uint128 internal storedExactAmount;
    bytes internal storedHookData;
    uint256 internal exactOutAmountIn;
    uint256 internal exactOutGas;
    uint256 internal exactInAmountOut;
    uint256 internal exactInGas;
    QuoteType internal lastQuoteType;

    function setExactOutResponse(uint256 amountIn_, uint256 gasEstimate) external {
        exactOutAmountIn = amountIn_;
        exactOutGas = gasEstimate;
    }

    function setExactInResponse(uint256 amountOut_, uint256 gasEstimate) external {
        exactInAmountOut = amountOut_;
        exactInGas = gasEstimate;
    }

    function quoteExactOutputSingle(IV4Quoter.QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        lastQuoteType = QuoteType.ExactOut;
        storedPoolKey = params.poolKey;
        storedZeroForOne = params.zeroForOne;
        storedExactAmount = params.exactAmount;
        storedHookData = params.hookData;
        return (exactOutAmountIn, exactOutGas);
    }

    function quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        lastQuoteType = QuoteType.ExactIn;
        storedPoolKey = params.poolKey;
        storedZeroForOne = params.zeroForOne;
        storedExactAmount = params.exactAmount;
        storedHookData = params.hookData;
        return (exactInAmountOut, exactInGas);
    }

    function lastPoolKey() external view returns (PoolKey memory) {
        return storedPoolKey;
    }

    function lastZeroForOne() external view returns (bool) {
        return storedZeroForOne;
    }

    function lastExactAmount() external view returns (uint128) {
        return storedExactAmount;
    }

    function lastHookDataLength() external view returns (uint256) {
        return storedHookData.length;
    }

    function lastHookData() external view returns (bytes memory) {
        return storedHookData;
    }

    function lastWasExactOut() external view returns (bool) {
        return lastQuoteType == QuoteType.ExactOut;
    }

    function lastWasExactIn() external view returns (bool) {
        return lastQuoteType == QuoteType.ExactIn;
    }
}

contract MockMulticurveInitializer {
    PoolKey internal storedKey;

    function setPoolKey(PoolKey memory poolKey) external {
        storedKey = poolKey;
    }

    function getState(address)
        external
        view
        returns (address numeraire, PoolStatus status, PoolKey memory poolKey, int24 farTick)
    {
        numeraire = address(0);
        status = PoolStatus.Initialized;
        poolKey = storedKey;
        farTick = 0;
    }
}
