pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {DopplerImplementation} from "./DopplerImplementation.sol";

using PoolIdLibrary for PoolKey;

contract BaseTest is Test, Deployers {
    // TODO: Maybe add the start and end ticks to the config?
    struct DopplerConfig {
        uint256 numTokensToSell;
        uint256 startingTime;
        uint256 endingTime;
        uint256 gamma;
        uint256 epochLength;
        uint24 fee;
        int24 tickSpacing;
    }

    // Constants

    uint256 constant DEFAULT_NUM_TOKENS_TO_SELL = 100_000e18;
    uint256 constant DEFAULT_STARTING_TIME = 1 days;
    uint256 constant DEFAULT_ENDING_TIME = 2 days;
    uint256 constant DEFAULT_GAMMA = 800;
    uint256 constant DEFAULT_EPOCH_LENGTH = 400 seconds;
    // default to feeless case for now
    uint24 constant DEFAULT_FEE = 0;
    int24 constant DEFAULT_TICK_SPACING = 8;

    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    DopplerConfig DEFAULT_DOPPLER_CONFIG = DopplerConfig({
        numTokensToSell: DEFAULT_NUM_TOKENS_TO_SELL,
        startingTime: DEFAULT_STARTING_TIME,
        endingTime: DEFAULT_ENDING_TIME,
        gamma: DEFAULT_GAMMA,
        epochLength: DEFAULT_EPOCH_LENGTH,
        fee: DEFAULT_FEE,
        tickSpacing: DEFAULT_TICK_SPACING
    });

    // Context

    DopplerImplementation hook = DopplerImplementation(
        address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        )
    );

    TestERC20 asset;
    TestERC20 numeraire;
    TestERC20 token0;
    TestERC20 token1;
    PoolId poolId;

    bool isToken0;
    int24 startTick;
    int24 endTick;

    // Users

    address alice = address(0xa71c3);
    address bob = address(0xb0b);

    // Deploy functions

    /// @dev Deploys a new pair of asset and numeraire tokens and the related Doppler hook
    /// with the default configuration.
    function _deploy() public {
        _deployTokens();
        _deployDoppler();
    }

    /// @dev Reuses an existing pair of asset and numeraire tokens and deploys the related
    /// Doppler hook with the default configuration.
    function _deploy(TestERC20 asset_, TestERC20 numeraire_) public {
        asset = asset_;
        numeraire = numeraire_;
        _deployDoppler();
    }

    /// @dev Deploys a new pair of asset and numeraire tokens and the related Doppler hook with
    /// a given configuration.
    function _deploy(DopplerConfig memory config) public {
        _deployTokens();
        _deployDoppler(config);
    }

    /// @dev Reuses an existing pair of asset and numeraire tokens and deploys the related Doppler
    /// hook with a given configuration.
    function _deploy(TestERC20 asset_, TestERC20 numeraire_, DopplerConfig memory config) public {
        asset = asset_;
        numeraire = numeraire_;
        _deployDoppler(config);
    }

    /// @dev Deploys a new pair of asset and numeraire tokens.
    function _deployTokens() public {
        asset = new TestERC20(2 ** 128);
        numeraire = new TestERC20(2 ** 128);
    }

    /// @dev Deploys a new Doppler hook with the default configuration.
    function _deployDoppler() public {
        _deployDoppler(DEFAULT_DOPPLER_CONFIG);
    }

    /// @dev Deploys a new Doppler hook with a given configuration.
    function _deployDoppler(DopplerConfig memory config) public {
        // isToken0 = asset < numeraire;
        vm.envOr("IS_TOKEN_0", true);
        (token0, token1) = asset < numeraire ? (asset, numeraire) : (numeraire, asset);
        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        (isToken0 ? token0 : token1).transfer(address(hook), config.numTokensToSell);

        // isToken0 ? startTick > endTick : endTick > startTick
        // In both cases, price(startTick) > price(endTick)
        startTick = isToken0 ? int24(0) : int24(0);
        endTick = isToken0 ? int24(-172_800) : int24(172_800);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(hook))
        });

        deployCodeTo(
            "DopplerImplementation.sol:DopplerImplementation",
            abi.encode(
                manager,
                key,
                config.numTokensToSell,
                config.startingTime,
                config.endingTime,
                startTick,
                endTick,
                config.epochLength,
                config.gamma,
                isToken0,
                hook
            ),
            address(hook)
        );

        poolId = key.toId();

        manager.initialize(key, TickMath.getSqrtPriceAtTick(startTick), new bytes(0));
    }

    function setUp() public virtual {
        manager = new PoolManager();
        _deploy();

        // Deploy swapRouter
        swapRouter = new PoolSwapTest(manager);

        // Deploy modifyLiquidityRouter
        // Note: Only used to validate that liquidity can't be manually modified
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Approve the router to spend tokens on behalf of the test contract
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
    }
}
