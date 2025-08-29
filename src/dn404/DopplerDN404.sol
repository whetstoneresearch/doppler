// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { DN404 } from "lib/dn404/src/DN404.sol";
import { DopplerDN404Mirror } from "src/dn404/DopplerDN404Mirror.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { LibString } from "solady/utils/LibString.sol";

/// @dev Thrown when trying to transfer tokens into the pool while it is locked
error PoolLocked();

/// @title DopplerDN404
/// @notice DN404-based asset token used by the Doppler protocol. From Doppler's point of view,
///         this behaves like a standard ERC20, while also exposing an ERC721 mirror.
contract DopplerDN404 is DN404, Ownable {

    uint256 private immutable UNIT;

    // ERC20 metadata
    string private _name;
    string private _symbol;

    // ERC721 metadata base URI
    string private _baseURI;


    /// @notice Address of the liquidity pool used for migration locking
    address public pool;

    /// @notice Whether the pool can receive tokens (unlocked) or not
    bool public isPoolUnlocked;

    mapping(address => uint256) public frozenBalances;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialTokenSupply,
        address initialSupplyOwner,
        address owner_,
        string memory baseURI_,
        uint256 unit_
    ) Ownable(owner_) {
        _name = name_;
        _symbol = symbol_;
        _baseURI = baseURI_;

        UNIT = unit_;

        address mirror = address(new DopplerDN404Mirror(msg.sender));
        _initializeDN404(initialTokenSupply, initialSupplyOwner, mirror);
    }

    // ---- ERC20 metadata ----
    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }

    // ---- ERC721 metadata ----
    function _tokenURI(uint256 tokenId) internal view override returns (string memory result) {
        if (bytes(_baseURI).length != 0) {
            result = string(abi.encodePacked(_baseURI, LibString.toString(tokenId)));
        }
    }

    /// @notice Updates the base URI for NFT metadata
    function setBaseURI(string calldata baseURI_) external onlyOwner { _baseURI = baseURI_; }

    /// @notice Locks the pool, preventing it from receiving tokens
    /// @param pool_ Address of the pool to lock
    function lockPool(address pool_) external onlyOwner {
        pool = pool_;
        isPoolUnlocked = false;
    }

    function _unit() internal view override returns (uint256) {
        return UNIT;
    }

    /// @notice Unlocks the pool, allowing it to receive tokens
    function unlockPool() external onlyOwner { isPoolUnlocked = true; }

    function freezeTokenIDsByIndex(uint256[] memory tokenIDIndexes) external {
        uint256 amountToFreeze = tokenIDIndexes.length * UNIT;
        uint256 currentFrozen = frozenBalances[msg.sender];
        if (balanceOf(msg.sender) < currentFrozen + amountToFreeze) {
            revert("Not enough balance to freeze");
        }
        // Number of NFTs already frozen corresponds to the first `startIndex` slots.
        uint256 startIndex = currentFrozen / UNIT;
        frozenBalances[msg.sender] = currentFrozen + amountToFreeze;

        DN404Storage storage $ = _getDN404Storage();
        AddressData storage fromAddressData = $.addressData[msg.sender];
        Uint32Map storage fromOwned = $.owned[msg.sender];
        Uint32Map storage oo = $.oo;
        uint256 fromIndex = fromAddressData.ownedLength;

        // Move the selected token IDs to the beginning of the owned list, in-order.
        // DN404 burns/transfers from the end of the list first, so front items are protected.
        for (uint256 i = 0; i < tokenIDIndexes.length; i++) {
            uint256 tokenIDIndex = tokenIDIndexes[i];
            if (tokenIDIndex >= fromIndex) revert("Token ID index out of bounds");
            if (tokenIDIndex < startIndex) continue; // Already frozen.
            if (tokenIDIndex != startIndex) {
                uint32 tokenIDAtIndex = _get(fromOwned, tokenIDIndex);
                uint32 tokenIDAtStartIndex = _get(fromOwned, startIndex);
                // Swap positions in owned list.
                _set(fromOwned, tokenIDIndex, tokenIDAtStartIndex);
                _set(fromOwned, startIndex, tokenIDAtIndex);
                // Update owned index metadata for both swapped token IDs.
                _set(oo, _ownedIndex(tokenIDAtIndex), uint32(startIndex));
                _set(oo, _ownedIndex(tokenIDAtStartIndex), uint32(tokenIDIndex));
            }
            unchecked { startIndex++; }
        }
    }

    /// @inheritdoc DN404
    function _transfer(address from, address to, uint256 amount) internal override {
        if (to == pool && isPoolUnlocked == false) revert PoolLocked();
        // enforce sender cannot send frozen balance
        if (from != address(0) && balanceOf(from) - amount < frozenBalances[from]) {
            revert("Transfer exceeds available balance");
        }
        super._transfer(from, to, amount);
    }

    /// @dev Override direct NFT transfers to adjust frozen balance if a frozen ID is moved.
    /// Maintains the invariant that the first `frozenBalances[from]/UNIT` indices remain the
    /// frozen set (minus the transferred one), with minimal swaps:
    ///  - Move the last frozen token into the index of the transferred frozen token.
    ///  - Move the list's last element (that super() moved into the transferred index) to the
    ///    first unfrozen index (i.e., the new boundary) if it exists.
    function _transferFromNFT(address from, address to, uint256 id, address msgSender) internal override {
        DN404Storage storage $ = _getDN404Storage();
        uint256 F = frozenBalances[from] / UNIT;
        bool wasFrozen;
        uint256 i; // index of `id` in `from`'s owned list before transfer.
        if (F != 0) {
            i = _get($.oo, _ownedIndex(id));
            wasFrozen = i < F;
        }
        super._transferFromNFT(from, to, id, msgSender);
        if (wasFrozen) {
            // Compute target index for last frozen before decrement.
            uint256 j = F - 1;
            // New owned length after super.
            uint256 newLen = $.addressData[from].ownedLength;
            // Perform the minimal swaps to preserve the frozen prefix (minus `id`).
            // Only operate on indices that are < newLen (valid part of the list).
            if (j < newLen) {
                Uint32Map storage fromOwned = $.owned[from];
                Uint32Map storage oo = $.oo;
                // The element currently at `i` is what super() moved from the previous last index.
                // If `i` is within range, swap `i` <-> `j`.
                if (i < newLen) {
                    if (i != j) {
                        uint32 idAtI = _get(fromOwned, i);
                        uint32 idAtJ = _get(fromOwned, j);
                        _set(fromOwned, i, idAtJ);
                        _set(fromOwned, j, idAtI);
                        _set(oo, _ownedIndex(idAtI), uint32(j));
                        _set(oo, _ownedIndex(idAtJ), uint32(i));
                    }
                }
            }
            unchecked { frozenBalances[from] -= UNIT; }
        }
    }
}
