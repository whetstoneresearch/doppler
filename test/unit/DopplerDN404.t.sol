// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.7 <0.9.0;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { DopplerDN404, PoolLocked } from "src/dn404/DopplerDN404.sol";
import { DopplerDN404Mirror } from "src/dn404/DopplerDN404Mirror.sol";

uint256 constant INITIAL_SUPPLY = 1e23;
uint256 constant UNIT = 1000e18;
string constant NAME = "Doppler DN404";
string constant SYMBOL = "D404";
string constant BASE_URI = "https://example.com/token/";

contract DopplerDN404Test is Test {

    DopplerDN404 public token;
    DopplerDN404Mirror public mirror;

    function setUp() public {
        token = new DopplerDN404(
            NAME,
            SYMBOL,
            INITIAL_SUPPLY,
            address(this),
            address(this),
            BASE_URI,
            UNIT
        );
        mirror = DopplerDN404Mirror(payable(token.mirrorERC721()));
    }

    function test_constructor() public {
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.pool(), address(0));
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertFalse(token.isPoolUnlocked());
        // Mirror is linked and defaults: initial owner skips NFTs
        assertEq(token.mirrorERC721(), address(mirror));
        assertEq(mirror.baseERC20(), address(token));
        assertEq(mirror.balanceOf(address(this)), 0);
    }

    function test_setBaseURI() public {
        string memory newBaseURI = "https://new.example.com/token/";
        token.setBaseURI(newBaseURI);

        // check base uri is used correctly
        address receiver = address(0x123);
        token.transfer(receiver, UNIT);
        uint256 tokenId = 1;
        string memory expectedURI = string(abi.encodePacked(newBaseURI, "1"));
        assertEq(mirror.tokenURI(tokenId), expectedURI);
    }

    function test_setBaseURI_RevertsWhenNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xbeef)));
        token.setBaseURI("https://malicious.example/");
    }

    function test_lockPool() public {
        address pool = address(0xdeadbeef);
        token.lockPool(pool);
        assertEq(token.pool(), pool);
        assertFalse(token.isPoolUnlocked());
    }

    function test_lockPool_RevertsWhenInvalidOwner() public {
        address pool = address(0xdeadbeef);
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xbeef)));
        token.lockPool(pool);
    }

    function test_unlockPool() public {
        assertFalse(token.isPoolUnlocked());
        token.unlockPool();
        assertTrue(token.isPoolUnlocked());
    }

    function test_unlockPool_RevertsWhenInvalidOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xbeef)));
        token.unlockPool();
    }

    function test_transfer_RevertsWhenPoolLocked() public {
        address pool = address(0xdeadbeef);
        token.lockPool(pool);
        vm.expectRevert(PoolLocked.selector);
        token.transfer(pool, 1);
    }

    function test_transferFrom_RevertsWhenPoolLocked() public {
        address pool = address(0xdeadbeef);
        token.lockPool(pool);
        token.approve(address(0xbeef), 1);
        vm.prank(address(0xbeef));
        vm.expectRevert(PoolLocked.selector);
        token.transferFrom(address(this), pool, 1);
    }

    function test_transfer_AllowsToPoolWhenUnlocked() public {
        address pool = address(0xdeadbeef);
        token.lockPool(pool);
        token.unlockPool();
        token.transfer(pool, 1);
        assertEq(token.balanceOf(pool), 1);
    }

    function test_mirror_MetadataMatchesBase() public {
        assertEq(mirror.name(), NAME);
        assertEq(mirror.symbol(), SYMBOL);
        assertEq(mirror.baseERC20(), address(token));
    }

    function test_mirror_tokenURI_UsesBaseURI() public {
        // initial base URI set in constructor
        address alice = address(0xa11ce);
        token.transfer(alice, UNIT);
        // first minted NFT should be ID 1 (one-indexed)
        assertEq(mirror.ownerOf(1), alice);
        string memory expectedURI = string(abi.encodePacked(BASE_URI, "1"));
        assertEq(mirror.tokenURI(1), expectedURI);
    }

    function test_mirror_ReflectsERC20Transfers() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);

        // Transfers to EOAs should mint NFTs automatically.
        token.transfer(alice, 3 * UNIT);
        assertEq(mirror.balanceOf(alice), 3);
        assertEq(mirror.totalSupply(), 3);

        // Transfer 2 units to a new EOA; should end up with 2 NFTs there.
        token.transfer(bob, 2 * UNIT);
        assertEq(mirror.balanceOf(bob), 2);
        assertEq(mirror.totalSupply(), 5);

        // Alice sends 1 unit to Bob, moving 1 NFT from Alice to Bob.
        vm.prank(alice);
        token.transfer(bob, UNIT);
        assertEq(mirror.balanceOf(alice), 2);
        assertEq(mirror.balanceOf(bob), 3);
        assertEq(mirror.totalSupply(), 5);
    }

    function test_skipNFT_TogglingPreventsMintOnTransfer() public {
        address alice = address(0xa11ce);
        // Toggle skipNFT to true for EOA `alice`.
        vm.prank(alice);
        token.setSkipNFT(true);

        // Transfer one unit to alice; should NOT mint an NFT due to skipNFT.
        token.transfer(alice, UNIT);
        assertEq(token.balanceOf(alice), UNIT);
        assertEq(mirror.balanceOf(alice), 0);
        // No NFTs exist globally as well.
        assertEq(mirror.totalSupply(), 0);
    }

}
