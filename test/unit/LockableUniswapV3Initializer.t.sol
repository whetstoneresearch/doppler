/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { WETH } from "@solmate/tokens/WETH.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Factory } from "@v3-core/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@v3-core/interfaces/IUniswapV3Pool.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { IQuoterV2 } from "@v3-periphery/interfaces/IQuoterV2.sol";
import { ISwapRouter } from "@v3-periphery/interfaces/ISwapRouter.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Test } from "forge-std/Test.sol";
import { BeneficiaryData } from "src/StreamableFeesLocker.sol";
import { SenderNotAirlock } from "src/base/ImmutableAirlock.sol";
import {
    CallbackData,
    InitData,
    InvalidFee,
    InvalidTickRange,
    InvalidTickRangeMisordered,
    LockableUniswapV3Initializer,
    MaxShareToBeSoldExceeded,
    OnlyPool,
    PoolAlreadyExited,
    PoolAlreadyInitialized,
    PoolStatus,
    WAD
} from "src/initializers/LockableUniswapV3Initializer.sol";
import { DERC20 } from "src/tokens/DERC20.sol";
import { UNISWAP_V3_ROUTER_MAINNET } from "test/shared/Addresses.sol";

int24 constant DEFAULT_LOWER_TICK = 167_520;
int24 constant DEFAULT_UPPER_TICK = 200_040;
int24 constant DEFAULT_TARGET_TICK = 167_520 + 12_000;
int24 constant DEFAULT_TARGET_TICK_DELTA = 12_000;
uint256 constant DEFAULT_MAX_SHARE_TO_BE_SOLD = 0.23 ether;
uint16 constant DEFAULT_NUM_POSITIONS = 10;

contract LockableUniswapV3InitializerTest is Test {
    LockableUniswapV3Initializer public initializer;
    address public airlockOwner = makeAddr("airlockOwner");

    function setUp() public {
        // vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC_URL"), 28_099_832);
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 21_093_509);
        initializer = new LockableUniswapV3Initializer(
            address(this), IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984)
        );
    }

    /// @dev Used to mimic the Airlock `owner()` function
    function owner() public view returns (address) {
        return airlockOwner;
    }

    function test_constructor() public view {
        assertEq(address(initializer.airlock()), address(this), "Wrong airlock");
        assertEq(address(initializer.factory()), address(0x1F98431c8aD98523631AE4a59f267346ea31F984), "Wrong factory");
    }

    function test_initialize() public returns (address pool) {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        pool = initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: getDefaultBeneficiaries()
                })
            )
        );

        assertEq(token.balanceOf(address(initializer)), 0, "Wrong initializer balance");

        uint128 totalLiquidity = IUniswapV3Pool(pool).liquidity();
        assertTrue(totalLiquidity > 0, "Wrong total liquidity");

        (uint128 liquidity,,,,) = IUniswapV3Pool(pool)
            .positions(
                keccak256(abi.encodePacked(address(initializer), int24(DEFAULT_LOWER_TICK), int24(DEFAULT_UPPER_TICK)))
            );
        assertEq(liquidity, totalLiquidity, "Wrong liquidity");
    }

    function test_initialize_InitializedStatus() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        address pool = initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );

        (,,,,,, PoolStatus status) = initializer.getState(pool);
        assertEq(uint8(status), uint8(PoolStatus.Initialized), "Pool status is not Initialized");
    }

    function test_initialize_LockedStatus() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        address pool = initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: getDefaultBeneficiaries()
                })
            )
        );

        (,,,,,, PoolStatus status) = initializer.getState(pool);
        assertEq(uint8(status), uint8(PoolStatus.Locked), "Pool status is not Locked");
    }

    function test_initialize_RevertsIfAlreadyInitialized() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );

        vm.expectRevert(PoolAlreadyInitialized.selector);
        initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );
    }

    function test_initialize_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.initialize(address(0), address(0), 0, bytes32(0), abi.encode());
    }

    function test_initialize_RevertsWhenMaxShareToBeSoldExceeded() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(MaxShareToBeSoldExceeded.selector, WAD + 1, WAD));
        initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: WAD + 1,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );
    }

    function test_initialize_RevertsWhenInvalidTickRange() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(InvalidTickRangeMisordered.selector, DEFAULT_UPPER_TICK, DEFAULT_LOWER_TICK)
        );
        initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_UPPER_TICK,
                    tickUpper: DEFAULT_LOWER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: WAD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );
    }

    function test_initialize_RevertsWhenInvalidTickLower() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(InvalidTickRange.selector, DEFAULT_LOWER_TICK - 1, 60));
        initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK - 1,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: WAD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );
    }

    function test_initialize_RevertsWhenInvalidTickUpper() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(InvalidTickRange.selector, DEFAULT_UPPER_TICK + 1, 60));
        initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK + 1,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: WAD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );
    }

    function test_initialize_RevertsWhenInvalidFee() public {
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        token.approve(address(initializer), type(uint256).max);

        uint24 fee = 2000;

        vm.expectRevert(abi.encodeWithSelector(InvalidFee.selector, fee));
        initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: fee,
                    tickLower: DEFAULT_LOWER_TICK,
                    tickUpper: DEFAULT_UPPER_TICK,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: WAD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );
    }

    function test_collectFees() public returns (address pool) {
        DERC20 token0 =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        DERC20 token1 =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");

        address asset = address(token0);
        address numeraire = address(token1);

        token0.approve(address(initializer), type(uint256).max);

        bool isToken0 = true;

        int24 tickLower = isToken0 ? -DEFAULT_UPPER_TICK : DEFAULT_LOWER_TICK;
        int24 tickUpper = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_UPPER_TICK;

        BeneficiaryData[] memory beneficiaries = getDefaultBeneficiaries();

        pool = initializer.initialize(
            asset,
            numeraire,
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: beneficiaries
                })
            )
        );

        token1.approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        uint256 amountIn = 1 ether;

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: numeraire,
                    tokenOut: asset,
                    fee: 3000,
                    recipient: address(0x666),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );

        uint256 expectedFees1 = amountIn - amountIn * 3000 / 1_000_000;

        (uint256 fees0ToDistribute, uint256 fees1ToDistribute) = initializer.collectFees(pool);

        for (uint256 i; i < beneficiaries.length; i++) {
            BeneficiaryData memory beneficiary = beneficiaries[i];
            // TODO: Instead of an approx we should compute the actual value: the last
            // beneficiary will receive their shares + dust due to rounding
            assertApproxEqAbs(
                token1.balanceOf(beneficiary.beneficiary),
                fees1ToDistribute * beneficiary.shares / WAD,
                1,
                string.concat("Incorrect fees1 for beneficiary", vm.toString(i))
            );
        }
    }

    function test_exitLiquidity() public returns (address pool) {
        bool isToken0;
        DERC20 token =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        while (address(token) < address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)) {
            token = new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        }

        isToken0 = address(token) < address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        token.approve(address(initializer), type(uint256).max);

        int24 tickLower = isToken0 ? -DEFAULT_UPPER_TICK : DEFAULT_LOWER_TICK;
        int24 tickUpper = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_UPPER_TICK;
        int24 targetTick = isToken0 ? -DEFAULT_LOWER_TICK : DEFAULT_LOWER_TICK;

        pool = initializer.initialize(
            address(token),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            1e27,
            bytes32(0),
            abi.encode(
                InitData({
                    fee: 3000,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    numPositions: DEFAULT_NUM_POSITIONS,
                    maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                    beneficiaries: new BeneficiaryData[](0)
                })
            )
        );

        deal(address(this), 100_000_000 ether);
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)).deposit{ value: 100_000_000 ether }();
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)).approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        // (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        uint160 priceLimit = TickMath.getSqrtPriceAtTick(isToken0 ? targetTick + 60 : targetTick - 60);

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    tokenOut: address(token),
                    fee: 3000,
                    recipient: address(0x666),
                    deadline: block.timestamp,
                    amountIn: 1000 ether,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: priceLimit
                })
            );

        // (, currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        // for debugging
        // (
        //     uint160 sqrtPriceX96,
        //     int24 tickEnd,
        //     uint16 observationIndex,
        //     uint16 observationCardinality,
        //     uint16 observationCardinalityNext,
        //     uint8 feeProtocol,
        //     bool unlocked
        // ) = IUniswapV3Pool(pool).slot0();
        initializer.exitLiquidity(pool);

        (uint128 liquidity,,,,) =
            IUniswapV3Pool(pool).positions(keccak256(abi.encodePacked(address(initializer), tickLower, tickUpper)));
        assertEq(liquidity, 0, "Position liquidity is not empty");
        assertApproxEqAbs(ERC20(token0).balanceOf(address(pool)), 0, 1000, "Pool token0 balance is not empty");
        assertApproxEqAbs(ERC20(token1).balanceOf(address(pool)), 0, 1000, "Pool token1 balance is not empty");
        assertEq(IUniswapV3Pool(pool).liquidity(), 0, "Pool liquidity is not empty");
        assertEq(ERC20(token0).balanceOf(address(initializer)), 0, "Initializer balance0 is not zero");
        assertEq(ERC20(token1).balanceOf(address(initializer)), 0, "Initializer balance1 is not zero");
    }

    function test_exitLiquidity_RevertsWhenAlreadyExited() public {
        address pool = test_exitLiquidity();
        vm.expectRevert(PoolAlreadyExited.selector);
        initializer.exitLiquidity(pool);
    }

    function test_exitLiquidity_RevertsWhenPoolLocked() public {
        address pool = test_initialize();
        vm.expectRevert(PoolAlreadyExited.selector);
        initializer.exitLiquidity(pool);
    }

    function test_exitLiquidity_RevertsWhenSenderNotAirlock() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(SenderNotAirlock.selector);
        initializer.exitLiquidity(address(0));
    }

    function test_uniswapV3MintCallback_RevertsWhenSenderNotPool() public {
        vm.expectRevert(OnlyPool.selector);
        initializer.uniswapV3MintCallback(0, 0, abi.encode(CallbackData(address(0), address(0), 0)));
    }

    function test_initialize_token0AndToken1SamePrice() public {
        DERC20 isToken0 =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        while (address(isToken0) > address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)) {
            isToken0 =
                new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        }
        // will be isToken0
        DERC20 notIsToken0 =
            new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        while (address(notIsToken0) < address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)) {
            notIsToken0 =
                new DERC20("", "", 2e27, address(this), address(this), 0, 0, new address[](0), new uint256[](0), "");
        }
        isToken0.approve(address(initializer), type(uint256).max);
        notIsToken0.approve(address(initializer), type(uint256).max);

        assertTrue(address(isToken0) < address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), "isToken0 is not token0");
        assertTrue(
            address(notIsToken0) > address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), "notIsToken0 is not token1"
        );

        IUniswapV3Pool isToken0Pool = IUniswapV3Pool(
            initializer.initialize(
                address(isToken0),
                address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
                1e27,
                bytes32(0),
                abi.encode(
                    InitData({
                        fee: 3000,
                        tickLower: -DEFAULT_UPPER_TICK,
                        tickUpper: -DEFAULT_LOWER_TICK,
                        numPositions: DEFAULT_NUM_POSITIONS,
                        maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                        beneficiaries: new BeneficiaryData[](0)
                    })
                )
            )
        );
        IUniswapV3Pool notIsToken0Pool = IUniswapV3Pool(
            initializer.initialize(
                address(notIsToken0),
                address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
                1e27,
                bytes32(0),
                abi.encode(
                    InitData({
                        fee: 3000,
                        tickLower: DEFAULT_LOWER_TICK,
                        tickUpper: DEFAULT_UPPER_TICK,
                        numPositions: DEFAULT_NUM_POSITIONS,
                        maxShareToBeSold: DEFAULT_MAX_SHARE_TO_BE_SOLD,
                        beneficiaries: new BeneficiaryData[](0)
                    })
                )
            )
        );

        assertEq(isToken0Pool.token0(), address(isToken0), "isToken0Pool token0 is not isToken0");
        assertEq(notIsToken0Pool.token1(), address(notIsToken0), "notIsToken0Pool token1 is not notIsToken0");
        assertEq(
            isToken0Pool.token1(),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            "isToken0Pool token1 is not 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
        );
        assertEq(
            notIsToken0Pool.token0(),
            address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2),
            "notIsToken0Pool token0 is not 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
        );

        deal(address(this), 1000 ether);
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)).deposit{ value: 1000 ether }();
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)).approve(UNISWAP_V3_ROUTER_MAINNET, type(uint256).max);

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    tokenOut: address(isToken0),
                    fee: 3000,
                    recipient: address(0x666),
                    deadline: block.timestamp,
                    amountIn: 1 ether,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(DEFAULT_UPPER_TICK)
                })
            );

        ISwapRouter(UNISWAP_V3_ROUTER_MAINNET)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                    tokenOut: address(notIsToken0),
                    fee: 3000,
                    recipient: address(0x666),
                    deadline: block.timestamp,
                    amountIn: 1 ether,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(DEFAULT_LOWER_TICK)
                })
            );

        uint256 isToken0Balance = isToken0.balanceOf(address(0x666));
        uint256 notIsToken0Balance = notIsToken0.balanceOf(address(0x666));
        assertApproxEqAbs(isToken0Balance, notIsToken0Balance, 1e9, "isToken0 and notIsToken0 balances are not equal");

        (,,, int24 tickUpperIsToken0,,,) = initializer.getState(address(isToken0Pool));
        (,, int24 tickLowerNotIsToken0,,,,) = initializer.getState(address(notIsToken0Pool));

        uint160 sqrtPriceTargetTickIsToken0 = TickMath.getSqrtPriceAtTick(tickUpperIsToken0 + 1);
        uint160 sqrtPriceTargetTickNotIsToken0 = TickMath.getSqrtPriceAtTick(tickLowerNotIsToken0 - 1);

        IQuoterV2 quoter = IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e);

        uint256 poolBalanceIsToken0 = isToken0.balanceOf(address(isToken0Pool));
        uint256 poolBalanceNotIsToken0 = notIsToken0.balanceOf(address(notIsToken0Pool));

        (uint256 maxWethIsToken0,,,) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                tokenOut: address(isToken0),
                fee: 3000,
                amount: poolBalanceIsToken0,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickUpperIsToken0)
            })
        );

        (uint256 maxWethNotIsToken0,,,) = quoter.quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                tokenOut: address(notIsToken0),
                fee: 3000,
                amount: poolBalanceNotIsToken0,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLowerNotIsToken0)
            })
        );

        uint256 low = 1000;
        uint256 high = maxWethIsToken0 - 1 ether;
        uint256 amountReceivedIsToken0;
        uint160 sqrtPriceX96AfterIsToken0;
        uint32 initializedTicksCrossedIsToken0;
        uint256 gasEstimateIsToken0;
        while (low < high) {
            uint256 mid = (low + high) / 2;

            (amountReceivedIsToken0, sqrtPriceX96AfterIsToken0, initializedTicksCrossedIsToken0, gasEstimateIsToken0) =
                quoter.quoteExactInputSingle(
                    IQuoterV2.QuoteExactInputSingleParams({
                        tokenIn: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                        tokenOut: address(isToken0),
                        fee: 3000,
                        amountIn: mid,
                        sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickUpperIsToken0)
                    })
                );

            if (sqrtPriceX96AfterIsToken0 < sqrtPriceTargetTickIsToken0) {
                low = mid + 1;
            } else if (sqrtPriceX96AfterIsToken0 > sqrtPriceTargetTickIsToken0) {
                high = mid;
            } else {
                break;
            }
        }

        low = 1000;
        high = maxWethNotIsToken0 - 1 ether;
        uint256 amountReceivedNotIsToken0;
        uint160 sqrtPriceX96AfterNotIsToken0;
        uint32 initializedTicksCrossedNotIsToken0;
        uint256 gasEstimateNotIsToken0;
        while (low < high) {
            uint256 mid = (low + high) / 2;

            (
                amountReceivedNotIsToken0,
                sqrtPriceX96AfterNotIsToken0,
                initializedTicksCrossedNotIsToken0,
                gasEstimateNotIsToken0
            ) =
                quoter.quoteExactInputSingle(
                    IQuoterV2.QuoteExactInputSingleParams({
                        tokenIn: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                        tokenOut: address(notIsToken0),
                        fee: 3000,
                        amountIn: mid,
                        sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tickLowerNotIsToken0)
                    })
                );

            if (sqrtPriceX96AfterNotIsToken0 > sqrtPriceTargetTickNotIsToken0) {
                low = mid + 1;
            } else if (sqrtPriceX96AfterNotIsToken0 < sqrtPriceTargetTickNotIsToken0) {
                high = mid;
            } else {
                break;
            }
        }
        assertApproxEqAbs(
            amountReceivedIsToken0,
            amountReceivedNotIsToken0,
            1e9,
            "amountReceivedIsToken0 and amountReceivedNotIsToken0 are not equal"
        );
    }

    function getDefaultBeneficiaries() internal view returns (BeneficiaryData[] memory beneficiaries) {
        beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: address(0x2), shares: 0.4 ether });
        beneficiaries[1] = BeneficiaryData({ beneficiary: address(0x3), shares: 0.55 ether });
        beneficiaries[2] = BeneficiaryData({ beneficiary: airlockOwner, shares: 0.05 ether });
    }
}
