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
        token = new DopplerDN404(NAME, SYMBOL, INITIAL_SUPPLY, address(this), address(this), BASE_URI, UNIT);
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

    function test_freezeTokenIDsByIndex_MovesToFrontAndProtects() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);

        // Give Alice 10 NFTs worth of tokens; EOAs mint NFTs automatically.
        token.transfer(alice, 10 * UNIT);
        assertEq(mirror.balanceOf(alice), 10);

        // For deterministic IDs, the 5th NFT has tokenId 5 owned by alice.
        assertEq(mirror.tokenOfOwnerByIndex(alice, 4), 5);

        // Freeze the 5th NFT by its index (zero-based index 4).
        uint256[] memory idx = new uint256[](1);
        idx[0] = 4;
        vm.prank(alice);
        token.freezeTokenIDsByIndex(idx);

        // Now sending 9 units should keep tokenId 5 with alice.
        vm.prank(alice);
        token.transfer(bob, 9 * UNIT);
        assertEq(mirror.balanceOf(alice), 1);
        // The remaining NFT at index 0 must be tokenId 5.
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 5);
    }

    function test_freezeTokenIDsByIndex_IndexOutOfBounds() public {
        address alice = address(0xa11ce);
        token.transfer(alice, 2 * UNIT);
        assertEq(mirror.balanceOf(alice), 2);
        uint256[] memory idx = new uint256[](1);
        idx[0] = 2; // out of bounds for length 2 (valid: 0,1)
        vm.prank(alice);
        vm.expectRevert(bytes("Token ID index out of bounds"));
        token.freezeTokenIDsByIndex(idx);
    }

    function test_freezeTokenIDsByIndex_TransferRespectsFrozenBalance() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        token.transfer(alice, 3 * UNIT);
        assertEq(mirror.balanceOf(alice), 3);

        // Freeze 2 NFTs (indexes 0 and 1).
        uint256[] memory idx = new uint256[](2);
        idx[0] = 0;
        idx[1] = 1;
        vm.prank(alice);
        token.freezeTokenIDsByIndex(idx);

        // Alice tries to send more than (balance - frozen) -> should revert.
        vm.prank(alice);
        vm.expectRevert(bytes("Transfer exceeds available balance"));
        token.transfer(bob, (3 * UNIT) - (2 * UNIT) + 1);

        // But she can send exactly (balance - frozen) units.
        vm.prank(alice);
        token.transfer(bob, 1 * UNIT);
        // 2 frozen NFTs remain with alice at indices 0 and 1.
        assertEq(mirror.balanceOf(alice), 2);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 2);
    }

    function test_directTransferFrozenNFT_DecrementsSenderFrozenBalance() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        token.transfer(alice, 2 * UNIT);
        assertEq(mirror.balanceOf(alice), 2);

        // Freeze token at index 0 (tokenId 1).
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        token.freezeTokenIDsByIndex(idx);
        assertEq(token.frozenBalances(alice), UNIT);

        // Transfer the frozen NFT directly via mirror.
        vm.prank(alice);
        mirror.transferFrom(alice, bob, 1);

        // Frozen balance decreased by UNIT; receiver unchanged.
        assertEq(token.frozenBalances(alice), 0);
        assertEq(token.frozenBalances(bob), 0);
        // Bob now has tokenId 1 at index 0; Alice keeps tokenId 2.
        assertEq(mirror.tokenOfOwnerByIndex(bob, 0), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 2);
    }

    function test_directTransferNonFrozenNFT_DoesNotAffectFrozenBalance() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        token.transfer(alice, 3 * UNIT);
        assertEq(mirror.balanceOf(alice), 3);

        // Freeze index 0 (tokenId 1).
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        token.freezeTokenIDsByIndex(idx);
        assertEq(token.frozenBalances(alice), UNIT);

        // Transfer a non-frozen NFT (tokenId 3) directly; frozen balance unchanged.
        vm.prank(alice);
        mirror.transferFrom(alice, bob, 3);

        assertEq(token.frozenBalances(alice), UNIT);
        assertEq(token.frozenBalances(bob), 0);
        // Bob owns tokenId 3; Alice owns tokenIds [1,2] in order.
        assertEq(mirror.tokenOfOwnerByIndex(bob, 0), 3);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 2);
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

    function test_tokenOfOwnerByIndex_BasicOrdering() public {
        address alice = address(0xa11ce);
        // Mint 5 NFTs worth of tokens to alice (EOA mints NFTs automatically).
        token.transfer(alice, 5 * UNIT);
        assertEq(mirror.balanceOf(alice), 5);

        // Expect sequential token IDs by index.
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 2);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 2), 3);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 3), 4);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 4), 5);

        // Out of bounds should revert.
        vm.expectRevert(bytes("Owner index out of bounds"));
        mirror.tokenOfOwnerByIndex(alice, 5);
    }

    function test_tokenOfOwnerByIndex_ReflectsSwapOnERC721Transfer() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        // Alice starts with 5 NFTs: IDs [1,2,3,4,5]
        token.transfer(alice, 5 * UNIT);
        assertEq(mirror.balanceOf(alice), 5);

        // Transfer tokenId 3 to bob via mirror (ERC721 transfer).
        vm.prank(alice);
        mirror.transferFrom(alice, bob, 3);

        // DN404 uses swap-and-pop, so alice's owned list becomes [1,2,5,4]
        assertEq(mirror.balanceOf(alice), 4);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 2);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 2), 5);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 3), 4);
        vm.expectRevert(bytes("Owner index out of bounds"));
        mirror.tokenOfOwnerByIndex(alice, 4);

        // Bob received tokenId 3 at index 0
        assertEq(mirror.balanceOf(bob), 1);
        assertEq(mirror.tokenOfOwnerByIndex(bob, 0), 3);
        vm.expectRevert(bytes("Owner index out of bounds"));
        mirror.tokenOfOwnerByIndex(bob, 1);
    }

    function test_tokenOfOwnerByIndex_ERC20UnitTransferMovesEndFirst() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        token.transfer(alice, 5 * UNIT);
        assertEq(mirror.balanceOf(alice), 5);

        // ERC20 unit transfer moves last NFT from alice to bob.
        vm.prank(alice);
        token.transfer(bob, UNIT);

        // Alice keeps [1,2,3,4]; Bob gets [5]
        assertEq(mirror.balanceOf(alice), 4);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 2);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 2), 3);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 3), 4);
        assertEq(mirror.balanceOf(bob), 1);
        assertEq(mirror.tokenOfOwnerByIndex(bob, 0), 5);
    }

    function test_tokenOfOwnerByIndex_RespectsFrozenReordering() public {
        address alice = address(0xa11ce);
        token.transfer(alice, 5 * UNIT);
        assertEq(mirror.balanceOf(alice), 5);

        // Freeze the NFT currently at index 2 (tokenId 3) and move it to the front.
        uint256[] memory idx = new uint256[](1);
        idx[0] = 2;
        vm.prank(alice);
        token.freezeTokenIDsByIndex(idx);

        // Expect owned order to be [3,2,1,4,5]
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 3);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 2);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 2), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 3), 4);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 4), 5);
    }

    function test_tokenOfOwnerByIndex_EmptyOwnerReverts() public {
        address nobody = address(0x1234);
        assertEq(mirror.balanceOf(nobody), 0);
        vm.expectRevert(bytes("Owner index out of bounds"));
        mirror.tokenOfOwnerByIndex(nobody, 0);
    }

    function test_tokenOfOwnerByIndex_SkipNFTRecipientEOA_Reverts() public {
        address alice = address(0xa11ce);
        vm.prank(alice);
        token.setSkipNFT(true);
        token.transfer(alice, 3 * UNIT);
        assertEq(mirror.balanceOf(alice), 0);
        vm.expectRevert(bytes("Owner index out of bounds"));
        mirror.tokenOfOwnerByIndex(alice, 0);
    }

    function test_tokenOfOwnerByIndex_SkipNFTRecipientContract_Reverts() public {
        NFTSkippingReceiver receiver = new NFTSkippingReceiver();
        // Contracts default to skipNFT=true.
        token.transfer(address(receiver), 2 * UNIT);
        assertEq(mirror.balanceOf(address(receiver)), 0);
        vm.expectRevert(bytes("Owner index out of bounds"));
        mirror.tokenOfOwnerByIndex(address(receiver), 0);
    }

    function test_tokenOfOwnerByIndex_MultiUnitTransferMovesLastTwo() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        token.transfer(alice, 5 * UNIT);
        assertEq(mirror.balanceOf(alice), 5);

        vm.prank(alice);
        token.transfer(bob, 2 * UNIT);

        // Alice loses last two: now [1,2,3]
        assertEq(mirror.balanceOf(alice), 3);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 2);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 2), 3);

        // Bob receives [5,4] in that order.
        assertEq(mirror.balanceOf(bob), 2);
        assertEq(mirror.tokenOfOwnerByIndex(bob, 0), 5);
        assertEq(mirror.tokenOfOwnerByIndex(bob, 1), 4);
    }

    function test_tokenOfOwnerByIndex_FreezeMultipleIndices_ReordersAsExpected() public {
        address alice = address(0xa11ce);
        token.transfer(alice, 5 * UNIT);
        assertEq(mirror.balanceOf(alice), 5);

        // Freeze indices [1,3] -> order becomes [2,4,3,1,5]
        uint256[] memory idx = new uint256[](2);
        idx[0] = 1;
        idx[1] = 3;
        vm.prank(alice);
        token.freezeTokenIDsByIndex(idx);

        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 2);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 4);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 2), 3);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 3), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 4), 5);
    }

    function test_tokenOfOwnerByIndex_MultipleFrozenThenTransferOne() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        token.transfer(alice, 5 * UNIT);
        assertEq(mirror.balanceOf(alice), 5);

        // Freeze indices [1,3] -> order becomes [2,4,3,1,5], frozen prefix size 2
        uint256[] memory idx = new uint256[](2);
        idx[0] = 1;
        idx[1] = 3;
        vm.prank(alice);
        token.freezeTokenIDsByIndex(idx);
        assertEq(token.frozenBalances(alice), 2 * UNIT);

        // Transfer a frozen NFT (tokenId 4) to bob via mirror.
        vm.prank(alice);
        mirror.transferFrom(alice, bob, 4);

        // Frozen balance decreased by one UNIT; first element of prefix (tokenId 2) remains at index 0.
        assertEq(token.frozenBalances(alice), 1 * UNIT);
        assertEq(mirror.balanceOf(alice), 4);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 2);
        // Remaining order becomes [2,5,3,1]
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 5);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 2), 3);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 3), 1);

        // Bob now owns tokenId 4
        assertEq(mirror.balanceOf(bob), 1);
        assertEq(mirror.tokenOfOwnerByIndex(bob, 0), 4);
    }

    function test_tokenByIndex_BasicGlobalEnumeration() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        // Mint 3 NFTs to alice and 2 to bob (EOAs auto-mint NFTs).
        token.transfer(alice, 3 * UNIT);
        token.transfer(bob, 2 * UNIT);

        // Total NFT supply should be 5.
        assertEq(mirror.totalSupply(), 5);
        // tokenByIndex should enumerate token IDs in ascending ID order.
        assertEq(mirror.tokenByIndex(0), 1);
        assertEq(mirror.tokenByIndex(1), 2);
        assertEq(mirror.tokenByIndex(2), 3);
        assertEq(mirror.tokenByIndex(3), 4);
        assertEq(mirror.tokenByIndex(4), 5);

        // Out of bounds should revert.
        vm.expectRevert(bytes("Global index out of bounds"));
        mirror.tokenByIndex(5);
    }

    function test_tokenByIndex_ReflectsBurnsAndGaps() public {
        address alice = address(0xa11ce);
        // Mint 5 NFTs to alice -> IDs [1..5].
        token.transfer(alice, 5 * UNIT);
        assertEq(mirror.totalSupply(), 5);

        // Transfer 2 units back to this contract (a contract defaults to skipNFT=true),
        // which burns alice's last 2 NFTs (IDs 5 and 4).
        vm.prank(alice);
        token.transfer(address(this), 2 * UNIT);

        // Total NFT supply now 3, IDs {1,2,3} should remain globally.
        assertEq(mirror.totalSupply(), 3);
        assertEq(mirror.tokenByIndex(0), 1);
        assertEq(mirror.tokenByIndex(1), 2);
        assertEq(mirror.tokenByIndex(2), 3);
        vm.expectRevert(bytes("Global index out of bounds"));
        mirror.tokenByIndex(3);
    }

    function test_tokenByIndex_MixedOwnersAndReordersDoNotAffectGlobalOrder() public {
        address alice = address(0xa11ce);
        address bob = address(0xb0b);
        // Mint 4 NFTs to alice -> IDs [1..4].
        token.transfer(alice, 4 * UNIT);
        // Transfer 1 unit from alice to bob (moves last NFT ID 4 to bob).
        vm.prank(alice);
        token.transfer(bob, UNIT);

        // Check per-owner ordering changes as expected.
        assertEq(mirror.balanceOf(alice), 3);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 1), 2);
        assertEq(mirror.tokenOfOwnerByIndex(alice, 2), 3);
        assertEq(mirror.balanceOf(bob), 1);
        assertEq(mirror.tokenOfOwnerByIndex(bob, 0), 4);

        // Global order remains by tokenId across all owners.
        assertEq(mirror.totalSupply(), 4);
        assertEq(mirror.tokenByIndex(0), 1);
        assertEq(mirror.tokenByIndex(1), 2);
        assertEq(mirror.tokenByIndex(2), 3);
        assertEq(mirror.tokenByIndex(3), 4);
    }
}

contract NFTSkippingReceiver { }
