// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { ERC20Votes } from "solady/tokens/ERC20Votes.sol";
import { Initializable } from "solady/utils/Initializable.sol";
import {
    ArrayLengthsMismatch,
    MAX_PRE_MINT_PER_ADDRESS_WAD,
    MAX_TOTAL_PRE_MINT_WAD,
    MAX_YEARLY_MINT_RATE_WAD,
    MaxPreMintPerAddressExceeded,
    MaxTotalPreMintExceeded,
    MaxTotalVestedExceeded,
    MaxYearlyMintRateExceeded,
    MintingNotStartedYet,
    NoMintableAmount,
    VestingData
} from "src/tokens/CloneERC20.sol";
import { WAD } from "src/types/Wad.sol";

/// @dev Thrown when trying to transfer tokens into the pool while it is locked
error PoolLocked();

/// @dev Thrown when there is no releasable amount
error NoReleasableAmount();

/// @dev Thrown when the schedule ID is out of range
error UnknownScheduleId(uint256 scheduleId);

/// @dev Thrown when a schedule is invalid (violates duration/cliff constraints)
error InvalidSchedule(uint256 scheduleId);

/// @dev Thrown when an allocation is invalid (zero address or zero amount)
error InvalidAllocation(uint256 index);

/// @dev Minimum vesting duration (prevents trivially short vesting periods)
uint256 constant MIN_VESTING_DURATION = 1 days;

/**
 * @notice Vesting schedule definition
 * @param cliff Seconds after vestingStart until tokens become claimable
 * @param duration Seconds after vestingStart until fully vested
 */
struct VestingSchedule {
    uint64 cliff;
    uint64 duration;
}

/// @notice Emitted when a new vesting schedule is created
event VestingScheduleCreated(uint256 indexed scheduleId, uint64 cliff, uint64 duration);

/// @notice Emitted when tokens are allocated to a beneficiary under a schedule
event VestingAllocated(address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);

/// @notice Emitted when tokens are released to a beneficiary
event TokensReleased(address indexed beneficiary, uint256 indexed scheduleId, uint256 amount);

/// @notice Emitted when the token URI is updated
event UpdateTokenURI(string tokenURI);

/// @notice Emitted when the yearly mint rate is updated
event UpdateMintRate(uint256 newMintRate);

/**
 * @title Clonable DERC20 V2
 * @author Whetstone Research
 * @notice Clonable ERC20 token with multi-schedule vesting, inflation, pool lock, votes and Permit2 support
 * @dev This contract is designed to be cloned using the ERC1167 minimal proxy pattern
 * @custom:security-contact security@whetstone.cc
 */
contract CloneDERC20VotesV2 is ERC20, Initializable, Ownable, ERC20Votes {
    /// @dev Name of the token
    string private _name;

    /// @dev Symbol of the token
    string private _symbol;

    /// @notice Uniform Resource Identifier (URI)
    string public tokenURI;

    /// @notice Timestamp of the start of all vesting schedules
    uint256 public vestingStart;

    /// @notice Total amount of vested tokens across all beneficiaries and schedules
    uint256 public vestedTotalAmount;

    /// @notice Address of the liquidity pool
    address public pool;

    /// @notice Whether the pool can receive tokens (unlocked) or not
    bool public isPoolLocked;

    /// @notice Maximum rate of tokens that can be minted in a year
    uint256 public yearlyMintRate;

    /// @notice Timestamp of the start of the current year
    uint256 public currentYearStart;

    /// @notice Timestamp of the last inflation mint
    uint256 public lastMintTimestamp;

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
     * @notice Initializes the token with the given parameters
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialSupply Initial supply of the token
     * @param recipient Address receiving the non-vested initial supply
     * @param owner_ Address receiving the ownership of the token
     * @param yearlyMintRate_ Maximum inflation rate of token in a year
     * @param schedules Array of vesting schedules
     * @param beneficiaries Array of beneficiary addresses for allocations
     * @param scheduleIds Array of schedule IDs corresponding to each allocation
     * @param amounts Array of amounts for each allocation
     * @param tokenURI_ Uniform Resource Identifier (URI)
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        address recipient,
        address owner_,
        uint256 yearlyMintRate_,
        VestingSchedule[] memory schedules,
        address[] memory beneficiaries,
        uint256[] memory scheduleIds,
        uint256[] memory amounts,
        string memory tokenURI_
    ) external initializer {
        _initializeOwner(owner_);

        // Validate yearly mint rate
        require(
            yearlyMintRate_ <= MAX_YEARLY_MINT_RATE_WAD,
            MaxYearlyMintRateExceeded(yearlyMintRate_, MAX_YEARLY_MINT_RATE_WAD)
        );

        _name = name_;
        _symbol = symbol_;
        yearlyMintRate = yearlyMintRate_;
        vestingStart = block.timestamp;
        tokenURI = tokenURI_;

        // Validate allocation array lengths
        uint256 allocationLength = beneficiaries.length;
        require(allocationLength == scheduleIds.length && allocationLength == amounts.length, ArrayLengthsMismatch());

        // Validate and store schedules
        uint256 schedulesLength = schedules.length;
        for (uint256 i; i < schedulesLength; i++) {
            VestingSchedule memory s = schedules[i];
            // Duration must be 0 (instant vest) or >= MIN_VESTING_DURATION
            // Cliff must be <= duration
            require(
                (s.duration == 0 || s.duration >= MIN_VESTING_DURATION) && s.cliff <= s.duration, InvalidSchedule(i)
            );
            vestingSchedules.push(s);
            emit VestingScheduleCreated(i, s.cliff, s.duration);
        }

        // Compute caps
        uint256 maxPreMintPerAddress = initialSupply * MAX_PRE_MINT_PER_ADDRESS_WAD / WAD;
        uint256 maxTotalPreMint = initialSupply * MAX_TOTAL_PRE_MINT_WAD / WAD;

        // Process allocations
        uint256 vestedTokens;
        for (uint256 i; i < allocationLength; i++) {
            address beneficiary = beneficiaries[i];
            uint256 scheduleId = scheduleIds[i];
            uint256 amount = amounts[i];

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
        require(vestedTokens <= initialSupply, MaxTotalVestedExceeded(vestedTokens, initialSupply));

        vestedTotalAmount = vestedTokens;

        // Mint tokens
        if (vestedTokens > 0) {
            _mint(address(this), vestedTokens);
        }
        _mint(recipient, initialSupply - vestedTokens);
    }

    /* ----------------------------------------------------------------------- */
    /*                                Pool Lock                                */
    /* ----------------------------------------------------------------------- */

    /**
     * @notice Locks the pool, preventing it from receiving tokens
     * @param pool_ Address of the pool to lock
     */
    function lockPool(address pool_) external onlyOwner {
        pool = pool_;
        isPoolLocked = true;
    }

    /// @notice Unlocks the pool, allowing it to receive tokens
    function unlockPool() external onlyOwner {
        isPoolLocked = false;
        currentYearStart = lastMintTimestamp = block.timestamp;
    }

    /* ---------------------------------------------------------------------------- */
    /*                                Supply Changes                                */
    /* ---------------------------------------------------------------------------- */

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
            yearMint = (supply * yearlyMintRate_ * timeLeftInCurrentYear) / (WAD * 365 days);
            supply += yearMint;
            mintableAmount += yearMint;
            currentYearStart_ += 365 days;
            lastMintTimestamp_ = currentYearStart_;
        }

        // Handle partial current year
        if (block.timestamp > lastMintTimestamp_) {
            uint256 partialYearMint =
                (supply * yearlyMintRate_ * (block.timestamp - lastMintTimestamp_)) / (WAD * 365 days);
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
        emit UpdateMintRate(newMintRate);
    }

    /**
     * @notice Updates the token Uniform Resource Identifier (URI)
     * @param tokenURI_ New token Uniform Resource Identifier (URI)
     */
    function updateTokenURI(string memory tokenURI_) external onlyOwner {
        tokenURI = tokenURI_;
        emit UpdateTokenURI(tokenURI_);
    }

    /* ----------------------------------------------------------------------------- */
    /*                                Vesting Release                                */
    /* ----------------------------------------------------------------------------- */

    /**
     * @notice Releases available vested tokens for a specific schedule
     * @param scheduleId Schedule ID to release from
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
     * @param beneficiary Bneficiary address
     * @param scheduleId Schedule ID to release from
     */
    function releaseFor(address beneficiary, uint256 scheduleId) external {
        _releaseFor(beneficiary, scheduleId);
    }

    /**
     * @notice Releases all available vested tokens for a beneficiary across all schedules
     * @dev Anyone can call; tokens always go to the beneficiary
     * @param beneficiary Beneficiary address
     */
    function releaseFor(address beneficiary) external {
        _releaseAllFor(beneficiary);
    }

    /* --------------------------------------------------------------------- */
    /*                                Getters                                */
    /* --------------------------------------------------------------------- */

    /// @notice Returns the number of vesting schedules
    function vestingScheduleCount() external view returns (uint256) {
        return vestingSchedules.length;
    }

    /**
     * @notice Returns the list of schedule IDs for a beneficiary
     * @param beneficiary Beneficiary address
     * @return Array of schedule IDs
     */
    function getScheduleIdsOf(address beneficiary) external view returns (uint256[] memory) {
        return _scheduleIdsOf[beneficiary];
    }

    /**
     * @notice Computes the available vested amount for a beneficiary under a specific schedule
     * @param beneficiary Beneficiary address
     * @param scheduleId Schedule ID
     * @return Amount available to release
     */
    function computeAvailableVestedAmount(address beneficiary, uint256 scheduleId) public view returns (uint256) {
        return _available(beneficiary, scheduleId);
    }

    /**
     * @notice Computes the total available vested amount for a beneficiary across all schedules
     * @param beneficiary Beneficiary address
     * @return total Total amount available to release
     */
    function computeAvailableVestedAmount(address beneficiary) public view returns (uint256 total) {
        uint256[] memory ids = _scheduleIdsOf[beneficiary];
        uint256 length = ids.length;
        for (uint256 i; i < length; i++) {
            total += _available(beneficiary, ids[i]);
        }
    }

    /* ----------------------------------------------------------------------- */
    /*                                Internals                                */
    /* ----------------------------------------------------------------------- */

    /**
     * @dev Computes the available (releasable) amount for a beneficiary under a schedule
     * @param beneficiary Beneficiary address
     * @param scheduleId Schedule ID
     * @return Amount available to release
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
     * @param beneficiary Beneficiary address
     * @param scheduleId Schedule ID
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
     * @param beneficiary Beneficiary address
     */
    function _releaseAllFor(address beneficiary) internal {
        uint256[] memory ids = _scheduleIdsOf[beneficiary];
        uint256 length = ids.length;

        // First pass: compute available amounts and total
        uint256[] memory amounts = new uint256[](length);
        uint256 total;
        for (uint256 i; i < length; i++) {
            amounts[i] = _available(beneficiary, ids[i]);
            total += amounts[i];
        }

        require(total > 0, NoReleasableAmount());

        // Second pass: update state and emit events
        for (uint256 i; i < length; i++) {
            if (amounts[i] > 0) {
                vestingOf[beneficiary][ids[i]].releasedAmount += amounts[i];
                emit TokensReleased(beneficiary, ids[i], amounts[i]);
            }
        }

        // Single transfer
        _transfer(address(this), beneficiary, total);
    }

    /* ----------------------------------------------------------------------- */
    /*                                Overrides                                */
    /* ----------------------------------------------------------------------- */

    /// @inheritdoc ERC20
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @inheritdoc ERC20
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc ERC20
    function _beforeTokenTransfer(address, address to, uint256) internal view override {
        if (to == pool && isPoolLocked) revert PoolLocked();
    }

    /// @inheritdoc ERC20
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return true;
    }

    /// @inheritdoc ERC20Votes
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20Votes, ERC20) {
        super._afterTokenTransfer(from, to, amount);
    }
}
