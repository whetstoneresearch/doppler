/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ERC20Votes } from "@openzeppelin/token/ERC20/extensions/ERC20Votes.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20Permit } from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import { Nonces } from "@openzeppelin/utils/Nonces.sol";

/// @dev Thrown when trying to mint before the start date
error MintingNotStartedYet();

/// @dev Thrown when trying to mint more than the yearly cap
error ExceedsYearlyMintCap();

/// @dev Thrown when trying to transfer tokens into the pool while it is locked
error PoolLocked();

/// @dev Thrown when two arrays have different lengths
error ArrayLengthsMismatch();

/// @dev Thrown when trying to release tokens before the end of the vesting period
error ReleaseAmountInvalid();

/// @dev Thrown when trying to premint more than the maximum allowed per address
error MaxPreMintPerAddressExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when trying to premint more than the maximum allowed in total
error MaxTotalPreMintExceeded(uint256 amount, uint256 limit);

/// @dev Max amount of tokens that can be pre-minted per address (% expressed in WAD)
uint256 constant MAX_PRE_MINT_PER_ADDRESS_WAD = 0.01 ether;

/// @dev Max amount of tokens that can be pre-minted in total (% expressed in WAD)
uint256 constant MAX_TOTAL_PRE_MINT_WAD = 0.1 ether;

/**
 * @notice Vesting data for a specific address
 * @param totalAmount Total amount of vested tokens
 * @param releasedAmount Amount of tokens already released
 */
struct VestingData {
    uint256 totalAmount;
    uint256 releasedAmount;
}

/// @custom:security-contact security@whetstone.cc
contract DERC20 is ERC20, ERC20Votes, ERC20Permit, Ownable {
    /// @notice Minting token will be possible after this timestamp
    uint256 public immutable mintStartDate;

    /// @notice Maximum amount of tokens that can be minted in a year
    uint256 public immutable yearlyMintCap;

    /// @notice Timestamp of the start of the vesting period
    uint256 public immutable vestingStart;

    /// @notice Duration of the vesting period (in seconds)
    uint256 public immutable vestingDuration;

    /// @notice Address of the liquidity pool
    address public pool;

    /// @notice Whether the pool can receive tokens (unlocked) or not
    bool public isPoolUnlocked;

    /// @notice Timestamp of the start of the current yearly period
    uint256 public currentYearStart;

    /// @notice Amount of tokens minted in the current year
    uint256 public currentAnnualMint;

    /// @notice Returns vesting data for a specific address
    mapping(address account => VestingData vestingData) public getVestingDataOf;

    /**
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialSupply Initial supply of the token
     * @param recipient Address receiving the initial supply
     * @param owner_ Address receivin the ownership of the token
     * @param yearlyMintCap_ Maximum amount of token that can be minted in a year
     * @param vestingDuration_ Duration of the vesting period (in seconds)
     * @param recipients_ Array of addresses receiving vested tokens
     * @param amounts_ Array of amounts of tokens to be vested
     */
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
        vestingStart = block.timestamp;
        vestingDuration = vestingDuration_;

        uint256 length = recipients_.length;
        require(length == amounts_.length, ArrayLengthsMismatch());

        uint256 vestedTokens;

        uint256 maxPreMintPerAddress = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1 ether;

        for (uint256 i; i < length; ++i) {
            uint256 amount = amounts_[i];
            getVestingDataOf[recipients_[i]].totalAmount += amount;
            require(
                getVestingDataOf[recipients_[i]].totalAmount <= maxPreMintPerAddress,
                MaxPreMintPerAddressExceeded(getVestingDataOf[recipients_[i]].totalAmount, maxPreMintPerAddress)
            );
            vestedTokens += amount;
        }

        uint256 maxTotalPreMint = initialSupply * MAX_TOTAL_PRE_MINT_WAD / 1 ether;
        require(vestedTokens <= maxTotalPreMint, MaxTotalPreMintExceeded(vestedTokens, maxTotalPreMint));

        _mint(address(this), vestedTokens);
        _mint(recipient, initialSupply - vestedTokens);
    }

    /**
     * @notice Locks the pool, preventing it from receiving tokens
     * @param pool_ Address of the pool to lock
     */
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

    /**
     * @notice Mints `amount` of tokens to the address `to`
     * @param to Address receiving the minted tokens
     * @param value Amount of tokens to mint
     */
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

    /**
     * @notice Releases `amount` of vested tokens
     * @param amount Amount of tokens to release
     */
    function release(
        uint256 amount
    ) external {
        uint256 vestedAmount;

        if (block.timestamp < vestingStart + vestingDuration) {
            vestedAmount = getVestingDataOf[msg.sender].totalAmount * (block.timestamp - vestingStart) / vestingDuration;
        } else {
            vestedAmount = getVestingDataOf[msg.sender].totalAmount;
        }

        getVestingDataOf[msg.sender].releasedAmount += amount;
        require(getVestingDataOf[msg.sender].releasedAmount <= vestedAmount, ReleaseAmountInvalid());

        _transfer(address(this), msg.sender, amount);
    }

    /// @inheritdoc Nonces
    function nonces(
        address owner
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /// @inheritdoc ERC20
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (to == pool && isPoolUnlocked == false) revert PoolLocked();

        super._update(from, to, value);
    }
}
