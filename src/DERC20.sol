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

error CannotReleaseYet();

error MaxPreMintPerAddressExceeded(uint256 amount, uint256 limit);

error MaxTotalPreMintExceeded(uint256 amount, uint256 limit);

// TODO: Set the values for these constants
uint256 constant MAX_PRE_MINT_PER_ADDRESS = 0;
uint256 constant MAX_TOTAL_PRE_MINT = 0;

/// @custom:security-contact security@whetstone.cc
contract DERC20 is ERC20, ERC20Votes, ERC20Permit, Ownable {
    uint256 public immutable mintStartDate;
    uint256 public immutable yearlyMintCap;
    uint256 public immutable vestingEnd;

    address public pool;
    uint256 public currentYearStart;
    uint256 public currentAnnualMint;

    bool public isPoolUnlocked;

    struct VestingDetails {
        uint256 amount;
    }

    mapping(address account => VestingDetails details) public getVestingOf;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address recipient,
        address owner_,
        uint256 yearlyMintCap_,
        uint256 vestingDuration_,
        address[] memory recipients_,
        uint256[] memory amounts_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        mintStartDate = block.timestamp + 365 days;
        yearlyMintCap = yearlyMintCap_;
        vestingEnd = block.timestamp + vestingDuration_;

        uint256 length = recipients_.length;
        require(length == amounts_.length, ArrayLengthsMismatch());

        uint256 vestedTokens;

        for (uint256 i; i < length; ++i) {
            uint256 amount = amounts_[i];
            require(amount <= MAX_PRE_MINT_PER_ADDRESS, MaxPreMintPerAddressExceeded(amount, MAX_PRE_MINT_PER_ADDRESS));
            getVestingOf[recipients_[i]].amount = amounts_[i];
            vestedTokens += amounts_[i];
        }

        require(vestedTokens <= MAX_TOTAL_PRE_MINT, MaxTotalPreMintExceeded(vestedTokens, MAX_TOTAL_PRE_MINT));

        _mint(address(this), vestedTokens);
        _mint(recipient, initialSupply - vestedTokens);
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

    function release(
        uint256 amount
    ) external {
        require(block.timestamp >= vestingEnd, CannotReleaseYet());
        getVestingOf[msg.sender].amount -= amount;
        _transfer(address(this), msg.sender, amount);
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
