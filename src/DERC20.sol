/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ERC20Votes } from "@openzeppelin/token/ERC20/extensions/ERC20Votes.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20Permit } from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import { Nonces } from "@openzeppelin/utils/Nonces.sol";

error MintingNotStartedYet();

error ExceedsYearlyMintCap();

error PoolLocked();

error ArrayLengthsMismatch();

/// @custom:security-contact security@whetstone.cc
contract DERC20 is ERC20, ERC20Votes, ERC20Permit, Ownable {
    uint256 public immutable mintStartDate;
    uint256 public immutable yearlyMintCap;

    address public pool;
    uint256 public currentYearStart;
    uint256 public currentAnnualMint;

    bool public isPoolUnlocked;

    address[] public recipients;
    uint256[] public amounts;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address recipient,
        address owner_,
        uint256 yearlyMintCap_,
        address[] memory recipients_,
        uint256[] memory amounts_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        _mint(recipient, initialSupply);
        mintStartDate = block.timestamp + 365 days;
        yearlyMintCap = yearlyMintCap_;

        require(recipients.length == amounts.length, ArrayLengthsMismatch());

        recipients = recipients_;
        amounts = amounts_;
    }

    function lockPool(
        address pool_
    ) external onlyOwner {
        pool = pool_;
        isPoolUnlocked = false;
    }

    /// @notice Unlocks the pool, allowing it to receive tokens
    function unlockPool() external onlyOwner {
        isPoolUnlocked = true;

        uint256 length = recipients.length;
        for (uint256 i; i < length; i++) {
            transfer(recipients[i], amounts[i]);
        }
    }

    function mint(address to, uint256 value) external onlyOwner {
        require(block.timestamp >= mintStartDate, MintingNotStartedYet());

        if (block.timestamp >= currentYearStart + 365 days) {
            currentYearStart = block.timestamp;
            currentAnnualMint = 0;
        }

        require(currentAnnualMint + value <= yearlyMintCap, ExceedsYearlyMintCap());
        currentAnnualMint += value;

        _mint(to, value);
    }

    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (to == pool && isPoolUnlocked == false) revert PoolLocked();

        super._update(from, to, value);
    }
}
