// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/token/ERC20/extensions/ERC20Votes.sol";
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

/// @dev Thrown when trying to premint more than the maximum allowed per address
error MaxPreMintPerAddressExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when trying to premint more than the maximum allowed in total
error MaxTotalPreMintExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when trying to mint more than the maximum allowed in total
error MaxTotalVestedExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when trying to set the mint rate to a value higher than the maximum allowed
error MaxYearlyMintRateExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when there is no releasable amount
error NoReleasableAmount();

/// @dev Thrown when the schedule ID is out of range
error UnknownScheduleId(uint256 scheduleId);

/// @dev Thrown when a schedule is invalid (violates duration/cliff constraints)
error InvalidSchedule(uint256 scheduleId);

/// @dev Minimum vesting duration (prevents trivially short vesting periods)
uint256 constant MIN_VESTING_DURATION = 1 days;

/// @dev Thrown when an allocation is invalid (zero address or zero amount)
error InvalidAllocation(uint256 index);

/// @dev Max amount of tokens that can be pre-minted per address (% expressed in WAD)
uint256 constant MAX_PRE_MINT_PER_ADDRESS_WAD = 0.8 ether;

/// @dev Max amount of tokens that can be pre-minted in total (% expressed in WAD)
uint256 constant MAX_TOTAL_PRE_MINT_WAD = 0.8 ether;

/// @dev Maximum amount of tokens that can be minted in a year (% expressed in WAD)
uint256 constant MAX_YEARLY_MINT_RATE_WAD = 0.02 ether;

/// @dev Address of the canonical Permit2 contract
address constant PERMIT_2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

/**
 * @notice Vesting schedule definition
 * @param cliff Seconds after vestingStart until tokens become claimable
 * @param duration Seconds after vestingStart until fully vested
 */
struct VestingSchedule {
    uint64 cliff;
    uint64 duration;
}

/**
 * @notice Vesting data for a specific (beneficiary, scheduleId) pair
 * @param totalAmount Total amount of vested tokens
 * @param releasedAmount Amount of tokens already released
 */
struct VestingData {
    uint256 totalAmount;
    uint256 releasedAmount;
}

/// @notice Emitted when a new vesting schedule is created
event VestingScheduleCreated(uint256 indexed scheduleId, uint64 cliff, uint64 duration);

/// @notice Emitted when tokens are allocated to a beneficiary under a schedule
event VestingAllocated(address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);

/// @notice Emitted when tokens are released to a beneficiary
event TokensReleased(address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);

/**
 * @title DERC20V2
 * @notice ERC20 token with multi-schedule vesting, inflation, pool lock, and Permit2 support
 * @dev Supports multiple vesting schedules with individual cliff and duration parameters.
 *      Each beneficiary can have allocations across multiple schedules.
 * @custom:security-contact security@whetstone.cc
 */
contract DERC20V2 is ERC20, ERC20Votes, ERC20Permit, Ownable {
    /// @notice Timestamp of the start of all vesting schedules
    uint256 public immutable vestingStart;

    /// @notice Total amount of vested tokens across all beneficiaries and schedules
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

    /// @notice Array of vesting schedules (scheduleId = index)
    VestingSchedule[] public vestingSchedules;

    /// @notice Vesting data for each (beneficiary, scheduleId) pair
    mapping(address beneficiary => mapping(uint256 scheduleId => VestingData)) public vestingOf;

    /// @notice Total allocated amount per beneficiary (for cap enforcement)
    mapping(address beneficiary => uint256) public totalAllocatedOf;

    /// @notice List of schedule IDs for each beneficiary
    mapping(address beneficiary => uint256[]) internal _scheduleIdsOf;

    /// @notice Whether a schedule ID is already in _scheduleIdsOf for a beneficiary
    mapping(address beneficiary => mapping(uint256 scheduleId => bool)) internal _hasSchedule;

    /**
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialSupply Initial supply of the token
     * @param recipient Address receiving the non-vested initial supply
     * @param owner_ Address receiving the ownership of the token
     * @param yearlyMintRate_ Maximum inflation rate of token in a year
     * @param schedules_ Array of vesting schedules
     * @param beneficiaries_ Array of beneficiary addresses for allocations
     * @param scheduleIds_ Array of schedule IDs corresponding to each allocation
     * @param amounts_ Array of amounts for each allocation
     * @param tokenURI_ Uniform Resource Identifier (URI)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address recipient,
        address owner_,
        uint256 yearlyMintRate_,
        VestingSchedule[] memory schedules_,
        address[] memory beneficiaries_,
        uint256[] memory scheduleIds_,
        uint256[] memory amounts_,
        string memory tokenURI_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        // Validate yearly mint rate
        require(
            yearlyMintRate_ <= MAX_YEARLY_MINT_RATE_WAD,
            MaxYearlyMintRateExceeded(yearlyMintRate_, MAX_YEARLY_MINT_RATE_WAD)
        );
        yearlyMintRate = yearlyMintRate_;
        vestingStart = block.timestamp;
        tokenURI = tokenURI_;

        // Validate allocation array lengths
        uint256 allocationLength = beneficiaries_.length;
        require(allocationLength == scheduleIds_.length && allocationLength == amounts_.length, ArrayLengthsMismatch());

        // Validate and store schedules
        uint256 schedulesLength = schedules_.length;
        for (uint256 i; i < schedulesLength; i++) {
            VestingSchedule memory s = schedules_[i];
            // Duration must be 0 (instant vest) or >= MIN_VESTING_DURATION
            // Cliff must be <= duration
            require(
                (s.duration == 0 || s.duration >= MIN_VESTING_DURATION) && s.cliff <= s.duration, InvalidSchedule(i)
            );
            vestingSchedules.push(s);
            emit VestingScheduleCreated(i, s.cliff, s.duration);
        }

        // Compute caps
        uint256 maxPreMintPerAddress = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / 1 ether;
        uint256 maxTotalPreMint = initialSupply * MAX_TOTAL_PRE_MINT_WAD / 1 ether;

        // Process allocations
        uint256 vestedTokens;
        for (uint256 i; i < allocationLength; i++) {
            address beneficiary = beneficiaries_[i];
            uint256 scheduleId = scheduleIds_[i];
            uint256 amount = amounts_[i];

            // Validate allocation
            require(beneficiary != address(0) && amount > 0, InvalidAllocation(i));
            require(scheduleId < schedulesLength, UnknownScheduleId(scheduleId));

            // Update per-beneficiary allocation and check cap
            totalAllocatedOf[beneficiary] += amount;
            require(
                totalAllocatedOf[beneficiary] <= maxPreMintPerAddress,
                MaxPreMintPerAddressExceeded(totalAllocatedOf[beneficiary], maxPreMintPerAddress)
            );

            // Update vesting data
            vestingOf[beneficiary][scheduleId].totalAmount += amount;

            // Track schedule IDs for this beneficiary
            if (!_hasSchedule[beneficiary][scheduleId]) {
                _hasSchedule[beneficiary][scheduleId] = true;
                _scheduleIdsOf[beneficiary].push(scheduleId);
            }

            vestedTokens += amount;
            emit VestingAllocated(beneficiary, scheduleId, amount);
        }

        // Enforce total premint cap
        require(vestedTokens <= maxTotalPreMint, MaxTotalPreMintExceeded(vestedTokens, maxTotalPreMint));
        require(vestedTokens < initialSupply, MaxTotalVestedExceeded(vestedTokens, initialSupply));

        vestedTotalAmount = vestedTokens;

        // Mint tokens
        if (vestedTokens > 0) {
            _mint(address(this), vestedTokens);
        }
        _mint(recipient, initialSupply - vestedTokens);
    }

    // =========================================================================
    // Pool Lock
    // =========================================================================

    /**
     * @notice Locks the pool, preventing it from receiving tokens
     * @param pool_ Address of the pool to lock
     */
    function lockPool(address pool_) external onlyOwner {
        pool = pool_;
        isPoolUnlocked = false;
    }

    /// @notice Unlocks the pool, allowing it to receive tokens
    function unlockPool() external onlyOwner {
        isPoolUnlocked = true;
        currentYearStart = lastMintTimestamp = block.timestamp;
    }

    // =========================================================================
    // Inflation
    // =========================================================================

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

        // Handle any outstanding full years
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
     * @notice Burns `amount` of tokens from the caller's balance
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Updates the maximum rate of tokens that can be minted in a year
     * @param newMintRate New maximum rate of tokens that can be minted in a year
     */
    function updateMintRate(uint256 newMintRate) external onlyOwner {
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
    function updateTokenURI(string memory tokenURI_) external onlyOwner {
        tokenURI = tokenURI_;
    }

    // =========================================================================
    // Vesting Views
    // =========================================================================

    /// @notice Returns the number of vesting schedules
    function vestingScheduleCount() external view returns (uint256) {
        return vestingSchedules.length;
    }

    /**
     * @notice Returns the vesting schedule parameters for a given schedule ID
     * @param scheduleId The schedule ID
     * @return cliff Seconds after vestingStart until tokens become claimable
     * @return duration Seconds after vestingStart until fully vested
     */
    function getVestingSchedule(uint256 scheduleId) external view returns (uint64 cliff, uint64 duration) {
        require(scheduleId < vestingSchedules.length, UnknownScheduleId(scheduleId));
        VestingSchedule memory s = vestingSchedules[scheduleId];
        return (s.cliff, s.duration);
    }

    /**
     * @notice Returns the list of schedule IDs for a beneficiary
     * @param beneficiary The beneficiary address
     * @return Array of schedule IDs
     */
    function getScheduleIdsOf(address beneficiary) external view returns (uint256[] memory) {
        return _scheduleIdsOf[beneficiary];
    }

    /**
     * @notice Computes the available vested amount for a beneficiary under a specific schedule
     * @param beneficiary The beneficiary address
     * @param scheduleId The schedule ID
     * @return The amount available to release
     */
    function computeAvailableVestedAmount(address beneficiary, uint256 scheduleId) public view returns (uint256) {
        return _available(beneficiary, scheduleId);
    }

    /**
     * @notice Computes the total available vested amount for a beneficiary across all schedules
     * @param beneficiary The beneficiary address
     * @return total The total amount available to release
     */
    function computeAvailableVestedAmount(address beneficiary) public view returns (uint256 total) {
        uint256[] memory ids = _scheduleIdsOf[beneficiary];
        uint256 length = ids.length;
        for (uint256 i; i < length;) {
            total += _available(beneficiary, ids[i]);
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // Vesting Release
    // =========================================================================

    /**
     * @notice Releases available vested tokens for a specific schedule
     * @param scheduleId The schedule ID to release from
     */
    function release(uint256 scheduleId) external {
        _releaseFor(msg.sender, scheduleId);
    }

    /**
     * @notice Releases all available vested tokens across all schedules for the caller
     */
    function release() external {
        _releaseAllFor(msg.sender);
    }

    /**
     * @notice Releases available vested tokens for a beneficiary under a specific schedule
     * @dev Anyone can call; tokens always go to the beneficiary
     * @param beneficiary The beneficiary address
     * @param scheduleId The schedule ID to release from
     */
    function releaseFor(address beneficiary, uint256 scheduleId) external {
        _releaseFor(beneficiary, scheduleId);
    }

    /**
     * @notice Releases all available vested tokens for a beneficiary across all schedules
     * @dev Anyone can call; tokens always go to the beneficiary
     * @param beneficiary The beneficiary address
     */
    function releaseFor(address beneficiary) external {
        _releaseAllFor(beneficiary);
    }

    // =========================================================================
    // Internal Vesting Logic
    // =========================================================================

    /**
     * @dev Computes the available (releasable) amount for a beneficiary under a schedule
     */
    function _available(address beneficiary, uint256 scheduleId) internal view returns (uint256) {
        VestingData storage vd = vestingOf[beneficiary][scheduleId];
        uint256 totalAmount = vd.totalAmount;
        if (totalAmount == 0) return 0;

        VestingSchedule memory s = vestingSchedules[scheduleId];
        uint256 t = block.timestamp;
        uint256 start = vestingStart;

        // Cliff gating: nothing claimable before cliff
        if (t < start + s.cliff) return 0;

        // Linear vesting from start
        uint256 vested;
        if (t >= start + s.duration) {
            vested = totalAmount;
        } else {
            vested = (totalAmount * (t - start)) / s.duration;
        }

        uint256 released = vd.releasedAmount;
        return vested > released ? vested - released : 0;
    }

    /**
     * @dev Releases tokens for a beneficiary from a specific schedule
     */
    function _releaseFor(address beneficiary, uint256 scheduleId) internal {
        require(scheduleId < vestingSchedules.length, UnknownScheduleId(scheduleId));

        uint256 amount = _available(beneficiary, scheduleId);
        require(amount > 0, NoReleasableAmount());

        vestingOf[beneficiary][scheduleId].releasedAmount += amount;
        _transfer(address(this), beneficiary, amount);
        emit TokensReleased(beneficiary, scheduleId, amount);
    }

    /**
     * @dev Releases tokens for a beneficiary across all their schedules
     */
    function _releaseAllFor(address beneficiary) internal {
        uint256[] memory ids = _scheduleIdsOf[beneficiary];
        uint256 length = ids.length;

        // First pass: compute available amounts and total
        uint256[] memory amounts = new uint256[](length);
        uint256 total;
        for (uint256 i; i < length;) {
            amounts[i] = _available(beneficiary, ids[i]);
            total += amounts[i];
            unchecked {
                ++i;
            }
        }

        require(total > 0, NoReleasableAmount());

        // Second pass: update state and emit events
        for (uint256 i; i < length;) {
            if (amounts[i] > 0) {
                vestingOf[beneficiary][ids[i]].releasedAmount += amounts[i];
                emit TokensReleased(beneficiary, ids[i], amounts[i]);
            }
            unchecked {
                ++i;
            }
        }

        // Single transfer
        _transfer(address(this), beneficiary, total);
    }

    // =========================================================================
    // Overrides
    // =========================================================================

    /// @inheritdoc Nonces
    function nonces(address owner_) public view override(ERC20Permit, Nonces) returns (uint256) {
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
