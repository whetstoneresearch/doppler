// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@v4-core-test/utils/Deployers.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { PoolManager, IPoolManager } from "@v4-core/PoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { BaseHook } from "@v4-periphery/utils/BaseHook.sol";

import { OpeningAuction } from "src/initializers/OpeningAuction.sol";
import { OpeningAuctionConfig } from "src/interfaces/IOpeningAuction.sol";
import {
    OpeningAuctionInitializer,
    OpeningAuctionDeployer,
    OpeningAuctionInitData,
    IncompatibleTickSpacing
} from "src/OpeningAuctionInitializer.sol";
import { Doppler } from "src/initializers/Doppler.sol";

/// @notice OpeningAuction implementation that bypasses hook address validation
contract OpeningAuctionTestImpl is OpeningAuction {
    constructor(
        IPoolManager poolManager_,
        address initializer_,
        uint256 totalAuctionTokens_,
        OpeningAuctionConfig memory config_
    ) OpeningAuction(poolManager_, initializer_, totalAuctionTokens_, config_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice OpeningAuctionDeployer that creates the implementation without address validation
contract OpeningAuctionDeployerTestImpl is OpeningAuctionDeployer {
    constructor(IPoolManager poolManager_) OpeningAuctionDeployer(poolManager_) {}

    function deploy(
        uint256 auctionTokens,
        bytes32 salt,
        bytes calldata data
    ) external override returns (OpeningAuction) {
        OpeningAuctionConfig memory config = abi.decode(data, (OpeningAuctionConfig));

        OpeningAuctionTestImpl auction = new OpeningAuctionTestImpl{salt: salt}(
            poolManager,
            msg.sender,
            auctionTokens,
            config
        );

        return OpeningAuction(payable(address(auction)));
    }
}

/// @notice Mock Doppler deployer that just returns a dummy address
contract MockDopplerDeployer {
    function deploy(uint256, bytes32, bytes calldata) external pure returns (Doppler) {
        // Return a dummy address - we won't actually use the Doppler in these tests
        return Doppler(payable(address(0xDEAD)));
    }
}

/// @notice Mock Airlock that allows anyone to call initialize
contract MockAirlock {
    address public immutable initializer;

    constructor(address _initializer) {
        initializer = _initializer;
    }
}

contract InitializerTickSpacingTest is Test, Deployers {
    // Tokens
    address constant TOKEN_A = address(0x8888);
    address constant TOKEN_B = address(0x9999);

    address asset;
    address numeraire;

    // Contracts
    OpeningAuctionInitializer initializer;
    OpeningAuctionDeployerTestImpl auctionDeployer;
    MockDopplerDeployer dopplerDeployer;
    MockAirlock airlock;

    // Test parameters
    uint256 constant AUCTION_TOKENS = 100_000_000 ether;
    uint256 constant AUCTION_DURATION = 1 days;

    function setUp() public {
        // Deploy pool manager
        manager = new PoolManager(address(this));

        // Deploy tokens
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_A);
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(2 ** 128), TOKEN_B);

        asset = TOKEN_A;
        numeraire = TOKEN_B;

        vm.label(asset, "Asset");
        vm.label(numeraire, "Numeraire");

        // Deploy auction and doppler deployers
        auctionDeployer = new OpeningAuctionDeployerTestImpl(manager);
        dopplerDeployer = new MockDopplerDeployer();

        // Deploy initializer with a mock airlock that points to this contract
        // We'll deploy a real initializer and mock the airlock call
        address initializerAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.AFTER_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG
            ) ^ (0x5555 << 144)
        );

        // First deploy the airlock mock
        airlock = new MockAirlock(initializerAddr);

        // Deploy the initializer to the calculated address
        deployCodeTo(
            "OpeningAuctionInitializer.sol:OpeningAuctionInitializer",
            abi.encode(
                address(airlock),
                address(manager),
                address(auctionDeployer),
                address(dopplerDeployer)
            ),
            initializerAddr
        );

        initializer = OpeningAuctionInitializer(initializerAddr);

        // Fund the airlock with tokens
        TestERC20(asset).transfer(address(airlock), AUCTION_TOKENS * 10);

        // Approve initializer to spend airlock's tokens
        vm.prank(address(airlock));
        TestERC20(asset).approve(address(initializer), type(uint256).max);
    }

    /// @notice Create auction config with specified tick spacing
    function getAuctionConfig(int24 tickSpacing) internal pure returns (OpeningAuctionConfig memory) {
        return OpeningAuctionConfig({
            auctionDuration: AUCTION_DURATION,
            minAcceptableTickToken0: -99_960,
            minAcceptableTickToken1: -99_960,
            incentiveShareBps: 1000,
            tickSpacing: tickSpacing,
            fee: 3000,
            minLiquidity: 1e15
        });
    }

    /// @notice Create Doppler data with specified tick spacing
    function getDopplerData(int24 dopplerTickSpacing) internal view returns (bytes memory) {
        return abi.encode(
            uint256(0),           // minimumProceeds
            uint256(1e30),        // maximumProceeds
            block.timestamp,      // startingTime
            block.timestamp + 7 days, // endingTime
            int24(0),             // startingTick (will be overwritten)
            int24(-100000),       // endingTick
            uint256(1 hours),     // epochLength
            int24(60),            // gamma
            true,                 // isToken0
            uint256(5),           // numPDSlugs
            uint24(3000),         // lpFee
            dopplerTickSpacing    // tickSpacing
        );
    }

    /// @notice Create init data for the initializer
    function getInitData(
        int24 auctionTickSpacing,
        int24 dopplerTickSpacing
    ) internal view returns (OpeningAuctionInitData memory) {
        return OpeningAuctionInitData({
            auctionConfig: getAuctionConfig(auctionTickSpacing),
            dopplerData: getDopplerData(dopplerTickSpacing)
        });
    }

    /* -------------------------------------------------------------------------- */
    /*                         Tick Spacing Compatibility Tests                    */
    /* -------------------------------------------------------------------------- */

    // Note: "Valid" tick spacing tests verify that IncompatibleTickSpacing is NOT thrown.
    // They will revert later with HookAddressNotValid (from pool initialization) because
    // we're not mining valid CREATE2 addresses in these unit tests. That's expected -
    // we're only testing the tick spacing validation logic here.

    function test_initialize_ValidTickSpacing_Equal() public {
        // Auction tick spacing = 30, Doppler tick spacing = 30
        // 30 % 30 == 0 ✓
        OpeningAuctionInitData memory initData = getInitData(30, 30);

        // Should NOT revert with IncompatibleTickSpacing
        // Will revert with HookAddressNotValid later (expected in unit tests)
        vm.prank(address(airlock));
        try initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(1)),
            abi.encode(initData)
        ) returns (address) {
            // If it succeeds, great
        } catch (bytes memory reason) {
            // Should NOT be IncompatibleTickSpacing
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != IncompatibleTickSpacing.selector,
                "Should not revert with IncompatibleTickSpacing for valid tick spacing"
            );
        }
    }

    function test_initialize_ValidTickSpacing_AuctionDouble() public {
        // Auction tick spacing = 60, Doppler tick spacing = 30
        // 60 % 30 == 0 ✓
        OpeningAuctionInitData memory initData = getInitData(60, 30);

        vm.prank(address(airlock));
        try initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(2)),
            abi.encode(initData)
        ) returns (address) {
            // Success
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != IncompatibleTickSpacing.selector,
                "Should not revert with IncompatibleTickSpacing for valid tick spacing"
            );
        }
    }

    function test_initialize_ValidTickSpacing_AuctionTriple() public {
        // Auction tick spacing = 90, Doppler tick spacing = 30
        // 90 % 30 == 0 ✓
        OpeningAuctionInitData memory initData = getInitData(90, 30);

        vm.prank(address(airlock));
        try initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(3)),
            abi.encode(initData)
        ) returns (address) {
            // Success
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != IncompatibleTickSpacing.selector,
                "Should not revert with IncompatibleTickSpacing for valid tick spacing"
            );
        }
    }

    function test_initialize_ValidTickSpacing_AuctionQuadruple() public {
        // Auction tick spacing = 120, Doppler tick spacing = 30
        // 120 % 30 == 0 ✓
        OpeningAuctionInitData memory initData = getInitData(120, 30);

        vm.prank(address(airlock));
        try initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(4)),
            abi.encode(initData)
        ) returns (address) {
            // Success
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != IncompatibleTickSpacing.selector,
                "Should not revert with IncompatibleTickSpacing for valid tick spacing"
            );
        }
    }

    function test_initialize_ValidTickSpacing_AuctionTenX() public {
        // Auction tick spacing = 300, Doppler tick spacing = 30
        // 300 % 30 == 0 ✓
        OpeningAuctionInitData memory initData = getInitData(300, 30);

        vm.prank(address(airlock));
        try initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(5)),
            abi.encode(initData)
        ) returns (address) {
            // Success
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != IncompatibleTickSpacing.selector,
                "Should not revert with IncompatibleTickSpacing for valid tick spacing"
            );
        }
    }

    function test_initialize_InvalidTickSpacing_NotDivisible() public {
        // Auction tick spacing = 50, Doppler tick spacing = 30
        // 50 % 30 == 20 ✗
        OpeningAuctionInitData memory initData = getInitData(50, 30);

        vm.expectRevert(abi.encodeWithSelector(IncompatibleTickSpacing.selector, int24(50), int24(30)));

        vm.prank(address(airlock));
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(6)),
            abi.encode(initData)
        );
    }

    function test_initialize_InvalidTickSpacing_45() public {
        // Auction tick spacing = 45, Doppler tick spacing = 30
        // 45 % 30 == 15 ✗
        OpeningAuctionInitData memory initData = getInitData(45, 30);

        vm.expectRevert(abi.encodeWithSelector(IncompatibleTickSpacing.selector, int24(45), int24(30)));

        vm.prank(address(airlock));
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(7)),
            abi.encode(initData)
        );
    }

    function test_initialize_InvalidTickSpacing_100() public {
        // Auction tick spacing = 100, Doppler tick spacing = 30
        // 100 % 30 == 10 ✗
        OpeningAuctionInitData memory initData = getInitData(100, 30);

        vm.expectRevert(abi.encodeWithSelector(IncompatibleTickSpacing.selector, int24(100), int24(30)));

        vm.prank(address(airlock));
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(8)),
            abi.encode(initData)
        );
    }

    function test_initialize_InvalidTickSpacing_SmallerThanDoppler() public {
        // Auction tick spacing = 15, Doppler tick spacing = 30
        // 15 % 30 == 15 ✗ (smaller auction tick spacing doesn't divide evenly)
        OpeningAuctionInitData memory initData = getInitData(15, 30);

        vm.expectRevert(abi.encodeWithSelector(IncompatibleTickSpacing.selector, int24(15), int24(30)));

        vm.prank(address(airlock));
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(9)),
            abi.encode(initData)
        );
    }

    function test_initialize_ValidTickSpacing_DifferentDopplerBase() public {
        // Auction tick spacing = 20, Doppler tick spacing = 10
        // 20 % 10 == 0 ✓
        OpeningAuctionInitData memory initData = getInitData(20, 10);

        vm.prank(address(airlock));
        try initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(10)),
            abi.encode(initData)
        ) returns (address) {
            // Success
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != IncompatibleTickSpacing.selector,
                "Should not revert with IncompatibleTickSpacing for valid tick spacing"
            );
        }
    }

    function test_initialize_InvalidTickSpacing_DifferentDopplerBase() public {
        // Auction tick spacing = 25, Doppler tick spacing = 10
        // 25 % 10 == 5 ✗
        OpeningAuctionInitData memory initData = getInitData(25, 10);

        vm.expectRevert(abi.encodeWithSelector(IncompatibleTickSpacing.selector, int24(25), int24(10)));

        vm.prank(address(airlock));
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(11)),
            abi.encode(initData)
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                              Fuzz Tests                                     */
    /* -------------------------------------------------------------------------- */

    function testFuzz_initialize_ValidTickSpacing(uint8 multiplier) public {
        // Bound multiplier to reasonable range (1-100)
        multiplier = uint8(bound(multiplier, 1, 100));

        int24 dopplerTickSpacing = 30;
        int24 auctionTickSpacing = dopplerTickSpacing * int24(uint24(multiplier));

        // Skip if tick spacing would be too large
        vm.assume(auctionTickSpacing <= type(int16).max);

        OpeningAuctionInitData memory initData = getInitData(auctionTickSpacing, dopplerTickSpacing);

        vm.prank(address(airlock));
        try initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(100 + multiplier)),
            abi.encode(initData)
        ) returns (address) {
            // Success
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector != IncompatibleTickSpacing.selector,
                "Should not revert with IncompatibleTickSpacing for valid tick spacing"
            );
        }
    }

    function testFuzz_initialize_InvalidTickSpacing(int24 auctionTickSpacing, int24 dopplerTickSpacing) public {
        // Bound to reasonable ranges
        auctionTickSpacing = int24(bound(auctionTickSpacing, 1, 1000));
        dopplerTickSpacing = int24(bound(dopplerTickSpacing, 1, 30));

        // Only test cases where the modulo is non-zero (invalid)
        vm.assume(auctionTickSpacing % dopplerTickSpacing != 0);

        OpeningAuctionInitData memory initData = getInitData(auctionTickSpacing, dopplerTickSpacing);

        vm.expectRevert(
            abi.encodeWithSelector(IncompatibleTickSpacing.selector, auctionTickSpacing, dopplerTickSpacing)
        );

        vm.prank(address(airlock));
        initializer.initialize(
            asset,
            numeraire,
            AUCTION_TOKENS,
            bytes32(uint256(1000 + uint24(auctionTickSpacing))),
            abi.encode(initData)
        );
    }
}
