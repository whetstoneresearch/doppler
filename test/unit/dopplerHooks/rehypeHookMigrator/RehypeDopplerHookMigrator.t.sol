// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { BalanceDeltaLibrary, toBalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolId } from "@v4-core/types/PoolId.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Test } from "forge-std/Test.sol";
import { SenderNotMigrator } from "src/base/BaseDopplerHookMigrator.sol";
import {
    FeeDistributionMustAddUpToWAD,
    RehypeDopplerHookMigrator,
    SenderNotAirlockOwner,
    SenderNotAuthorized
} from "src/dopplerHooks/RehypeDopplerHookMigrator.sol";
import { DopplerHookMigrator } from "src/migrators/DopplerHookMigrator.sol";
import { FeeDistributionInfo, HookFees, PoolInfo } from "src/types/RehypeTypes.sol";
import { WAD } from "src/types/Wad.sol";

contract MockPoolManager {
    // Minimal mock - just needs to exist for the quoter constructor
}

contract MockAirlockForMigrator {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }
}

contract MockMigratorForRehype {
    MockAirlockForMigrator public airlock;

    struct Pair {
        address token0;
        address token1;
    }

    mapping(address => Pair) internal _pairs;
    mapping(address => mapping(address => PoolKey)) internal _poolKeys;

    constructor(address airlockOwner) {
        airlock = new MockAirlockForMigrator(airlockOwner);
    }

    function setAirlockOwner(address _owner) external {
        airlock = new MockAirlockForMigrator(_owner);
    }

    function setPair(address asset, address token0, address token1) external {
        _pairs[asset] = Pair(token0, token1);
    }

    function setPoolKey(address token0, address token1, PoolKey memory key) external {
        _poolKeys[token0][token1] = key;
    }

    function getPair(address asset) external view returns (address, address) {
        return (_pairs[asset].token0, _pairs[asset].token1);
    }

    // Matches the auto-generated getter signature for mapping(token0 => mapping(token1 => AssetData))
    // AssetData has 9 fields, but BeneficiaryData[] (dynamic array) is skipped → 8 return values
    function getAssetData(
        address token0,
        address token1
    ) external view returns (bool, PoolKey memory, uint32, uint24, bool, address, bytes memory, uint8) {
        return (false, _poolKeys[token0][token1], 0, 0, false, address(0), new bytes(0), 0);
    }

    receive() external payable { }
}

contract RehypeDopplerHookMigratorTest is Test {
    RehypeDopplerHookMigrator internal rehypeHookMigrator;
    MockMigratorForRehype internal mockMigrator;
    IPoolManager internal poolManager;
    address public airlockOwner = makeAddr("AirlockOwner");

    function setUp() public {
        poolManager = IPoolManager(address(new MockPoolManager()));
        mockMigrator = new MockMigratorForRehype(airlockOwner);
        rehypeHookMigrator = new RehypeDopplerHookMigrator(
            DopplerHookMigrator(payable(address(mockMigrator))),
            poolManager
        );
    }

    /* --------------------------------------------------------------------------- */
    /*                                constructor()                                */
    /* --------------------------------------------------------------------------- */

    function test_constructor() public view {
        assertEq(address(rehypeHookMigrator.MIGRATOR()), address(mockMigrator));
        assertEq(address(rehypeHookMigrator.poolManager()), address(poolManager));
        assertTrue(address(rehypeHookMigrator.quoter()) != address(0));
    }

    /* -------------------------------------------------------------------------------- */
    /*                                onInitialization()                                */
    /* -------------------------------------------------------------------------------- */

    function test_onInitialization_StoresPoolInfo(bool isTokenZero, PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;
        address asset = Currency.unwrap(isTokenZero ? poolKey.currency0 : poolKey.currency1);
        address numeraire = Currency.unwrap(isTokenZero ? poolKey.currency1 : poolKey.currency0);
        address buybackDst = makeAddr("buybackDst");
        uint24 customFee = 3000; // 0.3%

        // Fee distribution that adds up to WAD
        uint256 assetBuybackPercentWad = 0.25e18;
        uint256 numeraireBuybackPercentWad = 0.25e18;
        uint256 beneficiaryPercentWad = 0.25e18;
        uint256 lpPercentWad = 0.25e18;

        bytes memory data = abi.encode(
            numeraire,
            buybackDst,
            customFee,
            assetBuybackPercentWad,
            numeraireBuybackPercentWad,
            beneficiaryPercentWad,
            lpPercentWad
        );

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Check pool info
        (address storedAsset, address storedNumeraire, address storedBuybackDst) =
            rehypeHookMigrator.getPoolInfo(poolId);
        assertEq(storedAsset, asset);
        assertEq(storedNumeraire, numeraire);
        assertEq(storedBuybackDst, buybackDst);

        // Check fee distribution info
        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            rehypeHookMigrator.getFeeDistributionInfo(poolId);
        assertEq(storedAssetBuyback, assetBuybackPercentWad);
        assertEq(storedNumeraireBuyback, numeraireBuybackPercentWad);
        assertEq(storedBeneficiary, beneficiaryPercentWad);
        assertEq(storedLp, lpPercentWad);

        // Check hook fees
        (
            uint128 fees0,
            uint128 fees1,
            uint128 beneficiaryFees0,
            uint128 beneficiaryFees1,
            uint128 airlockOwnerFees0,
            uint128 airlockOwnerFees1,
            uint24 storedCustomFee
        ) = rehypeHookMigrator.getHookFees(poolId);
        assertEq(storedCustomFee, customFee);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        assertEq(beneficiaryFees0, 0);
        assertEq(beneficiaryFees1, 0);
        assertEq(airlockOwnerFees0, 0);
        assertEq(airlockOwnerFees1, 0);
    }

    function test_onInitialization_InitializesPosition(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(3000), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        (int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt) = rehypeHookMigrator.getPosition(poolId);

        // Should be full range position
        assertTrue(tickLower < 0);
        assertTrue(tickUpper > 0);
        assertEq(liquidity, 0); // No liquidity yet
        assertTrue(salt != bytes32(0)); // Salt should be set
    }

    function test_onInitialization_RevertsWhenSenderNotMigrator(PoolKey memory poolKey) public {
        bytes memory data = abi.encode(address(0), address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.expectRevert(SenderNotMigrator.selector);
        rehypeHookMigrator.onInitialization(address(0), poolKey, data);
    }

    function test_onInitialization_RevertsWhenFeeDistributionDoesNotAddToWAD(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        // Fee distribution that doesn't add up to WAD
        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.24e18);

        vm.prank(address(mockMigrator));
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        rehypeHookMigrator.onInitialization(asset, poolKey, data);
    }

    function test_onInitialization_RevertsWhenFeeDistributionExceedsWAD(PoolKey memory poolKey) public {
        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        // Fee distribution that exceeds WAD
        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.5e18, 0.5e18, 0.5e18, 0.5e18);

        vm.prank(address(mockMigrator));
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        rehypeHookMigrator.onInitialization(asset, poolKey, data);
    }

    /* ---------------------------------------------------------------------- */
    /*                             onAfterSwap()                              */
    /* ---------------------------------------------------------------------- */

    function test_onAfterSwap_RevertsWhenSenderNotMigrator(
        PoolKey memory poolKey,
        IPoolManager.SwapParams memory swapParams
    ) public {
        vm.expectRevert(SenderNotMigrator.selector);
        rehypeHookMigrator.onAfterSwap(address(0), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));
    }

    function test_onAfterSwap_SkipsWhenSenderIsHook(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        vm.prank(address(mockMigrator));
        (Currency feeCurrency, int128 delta) = rehypeHookMigrator.onAfterSwap(
            address(rehypeHookMigrator),
            poolKey,
            IPoolManager.SwapParams(false, 1, 0),
            BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );

        assertEq(Currency.unwrap(feeCurrency), address(0));
        assertEq(delta, 0);
    }

    /* ---------------------------------------------------------------------- */
    /*                            onBeforeSwap()                              */
    /* ---------------------------------------------------------------------- */

    function test_onBeforeSwap_RevertsWhenSenderNotMigrator(
        PoolKey memory poolKey,
        IPoolManager.SwapParams memory swapParams
    ) public {
        vm.expectRevert(SenderNotMigrator.selector);
        rehypeHookMigrator.onBeforeSwap(address(0), poolKey, swapParams, new bytes(0));
    }

    function test_onBeforeSwap_SucceedsWhenCalledByMigrator(PoolKey memory poolKey) public {
        vm.prank(address(mockMigrator));
        // Should not revert - base implementation is a no-op
        rehypeHookMigrator.onBeforeSwap(address(0), poolKey, IPoolManager.SwapParams(false, 1, 0), new bytes(0));
    }

    /* ----------------------------------------------------------------------------- */
    /*                            setFeeDistribution()                               */
    /* ----------------------------------------------------------------------------- */

    function test_setFeeDistribution_UpdatesDistribution(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // Update fee distribution
        vm.prank(buybackDst);
        rehypeHookMigrator.setFeeDistribution(poolId, 0.5e18, 0, 0.5e18, 0);

        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            rehypeHookMigrator.getFeeDistributionInfo(poolId);

        assertEq(storedAssetBuyback, 0.5e18);
        assertEq(storedNumeraireBuyback, 0);
        assertEq(storedBeneficiary, 0.5e18);
        assertEq(storedLp, 0);
    }

    function test_setFeeDistribution_RevertsWhenSenderNotAuthorized(PoolKey memory poolKey) public {
        vm.expectRevert(SenderNotAuthorized.selector);
        rehypeHookMigrator.setFeeDistribution(poolKey.toId(), 0.25e18, 0.25e18, 0.25e18, 0.25e18);
    }

    function test_setFeeDistribution_RevertsWhenDoesNotAddToWAD(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        vm.prank(buybackDst);
        vm.expectRevert(FeeDistributionMustAddUpToWAD.selector);
        rehypeHookMigrator.setFeeDistribution(poolKey.toId(), 0.5e18, 0.5e18, 0.5e18, 0);
    }

    function test_setFeeDistribution_AllToBuybacks(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(3000), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        vm.prank(buybackDst);
        rehypeHookMigrator.setFeeDistribution(poolId, 0.5e18, 0.5e18, 0, 0);

        (uint256 a, uint256 n, uint256 b, uint256 l) = rehypeHookMigrator.getFeeDistributionInfo(poolId);
        assertEq(a, 0.5e18);
        assertEq(n, 0.5e18);
        assertEq(b, 0);
        assertEq(l, 0);
        assertEq(a + n + b + l, WAD);
    }

    function test_setFeeDistribution_CanBeCalledMultipleTimes(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(3000), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();

        // First update
        vm.prank(buybackDst);
        rehypeHookMigrator.setFeeDistribution(poolId, 0.5e18, 0, 0.5e18, 0);

        // Second update
        vm.prank(buybackDst);
        rehypeHookMigrator.setFeeDistribution(poolId, 0, 0, 0, WAD);

        (uint256 a, uint256 n, uint256 b, uint256 l) = rehypeHookMigrator.getFeeDistributionInfo(poolId);
        assertEq(a, 0);
        assertEq(n, 0);
        assertEq(b, 0);
        assertEq(l, WAD);
    }

    /* ----------------------------------------------------------------------------- */
    /*                              collectFees()                                    */
    /* ----------------------------------------------------------------------------- */

    function test_collectFees_ReturnsZeroWhenNoFees(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        // Verify hook fees are zero
        PoolId poolId = poolKey.toId();
        (,, uint128 beneficiaryFees0, uint128 beneficiaryFees1,,,) = rehypeHookMigrator.getHookFees(poolId);

        assertEq(beneficiaryFees0, 0);
        assertEq(beneficiaryFees1, 0);
    }

    /* ----------------------------------------------------------------------------- */
    /*                         claimAirlockOwnerFees()                               */
    /* ----------------------------------------------------------------------------- */

    function test_claimAirlockOwnerFees_RevertsWhenNotAirlockOwner(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(3000), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        // Setup mock migrator to return the pair and pool key
        mockMigrator.setPair(asset, token0, token1);
        mockMigrator.setPoolKey(token0, token1, poolKey);

        // Try to claim as non-airlock owner
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(SenderNotAirlockOwner.selector);
        rehypeHookMigrator.claimAirlockOwnerFees(asset);
    }

    function test_claimAirlockOwnerFees_ReturnsZeroWhenNoFees(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(3000), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        // Setup mock migrator
        mockMigrator.setPair(asset, token0, token1);
        mockMigrator.setPoolKey(token0, token1, poolKey);

        // Claim as airlock owner - should return 0 fees
        vm.prank(airlockOwner);
        (uint128 fees0, uint128 fees1) = rehypeHookMigrator.claimAirlockOwnerFees(asset);

        assertEq(fees0, 0);
        assertEq(fees1, 0);
    }

    /* ----------------------------------------------------------------------------- */
    /*                       onInitialization fee config variants                    */
    /* ----------------------------------------------------------------------------- */

    function test_onInitialization_AllFeesBeneficiary(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(10_000), 0, 0, WAD, 0);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            rehypeHookMigrator.getFeeDistributionInfo(poolId);

        assertEq(storedAssetBuyback, 0);
        assertEq(storedNumeraireBuyback, 0);
        assertEq(storedBeneficiary, WAD);
        assertEq(storedLp, 0);
    }

    function test_onInitialization_AllFeesLP(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(5000), 0, 0, 0, WAD);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (uint256 storedAssetBuyback, uint256 storedNumeraireBuyback, uint256 storedBeneficiary, uint256 storedLp) =
            rehypeHookMigrator.getFeeDistributionInfo(poolId);

        assertEq(storedAssetBuyback, 0);
        assertEq(storedNumeraireBuyback, 0);
        assertEq(storedBeneficiary, 0);
        assertEq(storedLp, WAD);
    }

    function test_onInitialization_ZeroCustomFee(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");

        bytes memory data = abi.encode(numeraire, buybackDst, uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (,,,,,, uint24 storedCustomFee) = rehypeHookMigrator.getHookFees(poolId);
        assertEq(storedCustomFee, 0);
    }

    /* ----------------------------------------------------------------------------- */
    /*                            Position tick spacing tests                        */
    /* ----------------------------------------------------------------------------- */

    function test_onInitialization_PositionTicksMatchTickSpacing(int24 tickSpacing) public {
        // Bound tickSpacing to valid range (1-16383)
        tickSpacing = int24(bound(int256(tickSpacing), 1, 16383));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(makeAddr("token0")),
            currency1: Currency.wrap(makeAddr("token1")),
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);

        bytes memory data = abi.encode(numeraire, address(0), uint24(0), 0.25e18, 0.25e18, 0.25e18, 0.25e18);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        PoolId poolId = poolKey.toId();
        (int24 tickLower, int24 tickUpper,,) = rehypeHookMigrator.getPosition(poolId);

        // Ticks should be aligned to tick spacing
        assertEq(tickLower % tickSpacing, 0, "tickLower should be aligned to tickSpacing");
        assertEq(tickUpper % tickSpacing, 0, "tickUpper should be aligned to tickSpacing");
    }

    /* ----------------------------------------------------------------------------- */
    /*                  onAfterSwap fee accumulation (no PoolManager)                */
    /* ----------------------------------------------------------------------------- */

    function test_onAfterSwap_AccumulatesFees(PoolKey memory poolKey) public {
        poolKey.tickSpacing = 60;

        address asset = Currency.unwrap(poolKey.currency0);
        address numeraire = Currency.unwrap(poolKey.currency1);
        address buybackDst = makeAddr("buybackDst");
        uint24 customFee = 10_000; // 1%

        // All fees go to beneficiary for simple testing
        bytes memory data = abi.encode(numeraire, buybackDst, customFee, 0, 0, WAD, 0);

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onInitialization(asset, poolKey, data);

        // Simulate a swap with amountSpecified < 0 (exact input) and zeroForOne = true
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(address(mockMigrator));
        rehypeHookMigrator.onAfterSwap(address(0x123), poolKey, swapParams, BalanceDeltaLibrary.ZERO_DELTA, new bytes(0));

        PoolId poolId = poolKey.toId();

        // Verify customFee was stored correctly
        (,,,,,, uint24 storedFee) = rehypeHookMigrator.getHookFees(poolId);
        assertEq(storedFee, customFee);
    }
}
