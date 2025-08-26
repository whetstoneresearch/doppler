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

    /// @inheritdoc DN404
    function _transfer(address from, address to, uint256 amount) internal override {
        if (to == pool && isPoolUnlocked == false) revert PoolLocked();
        super._transfer(from, to, amount);
    }
}

