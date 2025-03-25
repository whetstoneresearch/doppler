// SPDX-License-Identifier: BUSL-1.1
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

/// @dev Thrown when there is no amount to mint
error NoMintableAmount();

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

/// @dev Thrown when trying to mint more than the maximum allowed in total
error MaxTotalVestedExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when trying to release tokens before the vesting period has started
error VestingNotStartedYet();

/// @dev Thrown when trying to set the mint rate to a value higher than the maximum allowed
error MaxYearlyMintRateExceeded(uint256 amount, uint256 limit);

/// @dev Max amount of tokens that can be pre-minted per address (% expressed in WAD)
uint256 constant MAX_PRE_MINT_PER_ADDRESS_WAD = 0.1 ether;

/// @dev Max amount of tokens that can be pre-minted in total (% expressed in WAD)
uint256 constant MAX_TOTAL_PRE_MINT_WAD = 0.1 ether;

/// @dev Maximum amount of tokens that can be minted in a year (% expressed in WAD)
uint256 constant MAX_YEARLY_MINT_RATE_WAD = 0.02 ether;

/// @dev Address of the canonical Permit2 contract
address constant PERMIT_2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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
    /// @notice Timestamp of the start of the vesting period
    uint256 public immutable vestingStart;

    /// @notice Duration of the vesting period (in seconds)
    uint256 public immutable vestingDuration;

    /// @notice Total amount of vested tokens
    uint256 public immutable vestedTotalAmount;

    /// @notice Address of the liquidity pool
    address public pool;

    /// @notice Whether the pool can receive tokens (unlocked) or not
    bool public isPoolUnlocked;

    /// @notice Maximum rate of tokens that can be minted in a year
    uint256 public yearlyMintRate;

    /// @notice Timestamp of the start of the current year
    uint256 public currentYearStart;

    /// @notice Timestamp of the last inflation mint
    uint256 public lastMintTimestamp;

    /// @notice Uniform Resource Identifier (URI)
    string public tokenURI;

    /// @notice Returns vesting data for a specific address
    mapping(address account => VestingData vestingData) public getVestingDataOf;

    modifier hasVestingStarted() {
        require(vestingStart > 0, VestingNotStartedYet());
        _;
    }

    /**
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialSupply Initial supply of the token
     * @param recipient Address receiving the initial supply
     * @param owner_ Address receivin the ownership of the token
     * @param yearlyMintRate_ Maximum inflation rate of token in a year
     * @param vestingDuration_ Duration of the vesting period (in seconds)
     * @param recipients_ Array of addresses receiving vested tokens
     * @param amounts_ Array of amounts of tokens to be vested
     * @param tokenURI_ Uniform Resource Identifier (URI)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address recipient,
        address owner_,
        uint256 yearlyMintRate_,
        uint256 vestingDuration_,
        address[] memory recipients_,
        uint256[] memory amounts_,
        string memory tokenURI_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        require(
            yearlyMintRate_ <= MAX_YEARLY_MINT_RATE_WAD,
            MaxYearlyMintRateExceeded(yearlyMintRate_, MAX_YEARLY_MINT_RATE_WAD)
        );
        yearlyMintRate = yearlyMintRate_;
        vestingStart = block.timestamp;
        vestingDuration = vestingDuration_;
        tokenURI = tokenURI_;

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
        require(vestedTokens < initialSupply, MaxTotalVestedExceeded(vestedTokens, initialSupply));

        vestedTotalAmount = vestedTokens;

        if (vestedTokens > 0) {
            _mint(address(this), vestedTokens);
        }

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
        currentYearStart = lastMintTimestamp = block.timestamp;
    }

    /**
     * @notice Mints inflation tokens to the owner
     */
    function mintInflation() public {
        require(currentYearStart != 0, MintingNotStartedYet());

        uint256 mintableAmount;
        uint256 yearMint;
        uint256 timeLeftInCurrentYear;
        uint256 supply = totalSupply();
        uint256 currentYearStart_ = currentYearStart;
        uint256 lastMintTimestamp_ = lastMintTimestamp;
        uint256 yearlyMintRate_ = yearlyMintRate;
        // Handle any outstanding full years and updates to maintain inflation rate
        while (block.timestamp > currentYearStart_ + 365 days) {
            timeLeftInCurrentYear = (currentYearStart_ + 365 days - lastMintTimestamp_);
            yearMint = (supply * yearlyMintRate_ * timeLeftInCurrentYear) / (1 ether * 365 days);
            supply += yearMint;
            mintableAmount += yearMint;
            currentYearStart_ += 365 days;
            lastMintTimestamp_ = currentYearStart_;
        }

        // Handle partial current year
        if (block.timestamp > lastMintTimestamp_) {
            uint256 partialYearMint =
                (supply * yearlyMintRate_ * (block.timestamp - lastMintTimestamp_)) / (1 ether * 365 days);
            mintableAmount += partialYearMint;
        }

        require(mintableAmount > 0, NoMintableAmount());

        currentYearStart = currentYearStart_;
        lastMintTimestamp = block.timestamp;
        _mint(owner(), mintableAmount);
    }

    /**
     * @notice Burns `amount` of tokens from the address `owner`
     * @param amount Amount of tokens to burn
     */
    function burn(
        uint256 amount
    ) external onlyOwner {
        _burn(owner(), amount);
    }

    /**
     * @notice Updates the maximum rate of tokens that can be minted in a year
     * @param newMintRate New maximum rate of tokens that can be minted in a year
     */
    function updateMintRate(
        uint256 newMintRate
    ) external onlyOwner {
        // Inflation can't be more than 2% of token supply per year
        require(
            newMintRate <= MAX_YEARLY_MINT_RATE_WAD, MaxYearlyMintRateExceeded(newMintRate, MAX_YEARLY_MINT_RATE_WAD)
        );

        if (currentYearStart != 0 && (block.timestamp - lastMintTimestamp) != 0) {
            mintInflation();
        }

        yearlyMintRate = newMintRate;
    }

    /**
     * @notice Updates the token Uniform Resource Identifier (URI)
     * @param tokenURI_ New token Uniform Resource Identifier (URI)
     */
    function updateTokenURI(
        string memory tokenURI_
    ) external onlyOwner {
        tokenURI = tokenURI_;
    }

    /**
     * @notice Releases all available vested tokens
     */
    function release() external hasVestingStarted {
        uint256 availableAmount = computeAvailableVestedAmount(msg.sender);
        getVestingDataOf[msg.sender].releasedAmount += availableAmount;
        _transfer(address(this), msg.sender, availableAmount);
    }

    /**
     * @notice Computes the amount of vested tokens available for a specific address
     * @param account Recipient of the vested tokens
     * @return Amount of vested tokens available
     */
    function computeAvailableVestedAmount(
        address account
    ) public view returns (uint256) {
        uint256 vestedAmount;

        if (block.timestamp < vestingStart + vestingDuration) {
            vestedAmount = getVestingDataOf[account].totalAmount * (block.timestamp - vestingStart) / vestingDuration;
        } else {
            vestedAmount = getVestingDataOf[account].totalAmount;
        }

        return vestedAmount - getVestingDataOf[account].releasedAmount;
    }

    /// @inheritdoc Nonces
    function nonces(
        address owner_
    ) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner_);
    }

    /// @inheritdoc ERC20
    function allowance(address owner, address spender) public view override returns (uint256) {
        if (spender == PERMIT_2) return type(uint256).max;
        return super.allowance(owner, spender);
    }

    /// @inheritdoc ERC20
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (to == pool && isPoolUnlocked == false) revert PoolLocked();

        super._update(from, to, value);
    }
}
