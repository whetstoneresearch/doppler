// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { ERC20Votes } from "solady/tokens/ERC20Votes.sol";
import { Initializable } from "solady/utils/Initializable.sol";
import { WAD } from "src/types/Wad.sol";

/// @dev Thrown when two arrays have different lengths
error ArrayLengthsMismatch();

/// @dev Thrown when trying to transfer tokens into the pool while it is locked
error PoolLocked();

/// @dev Thrown when there is no releasable amount
error NoReleasableAmount();

/// @dev Thrown when there is no amount to mint
error NoMintableAmount();

/// @dev Thrown when trying to mint before the start date
error MintingNotStartedYet();

/// @dev Thrown when the balance limit is not active
error BalanceLimitNotActive();

/// @dev Thrown when the schedule ID is out of range
error UnknownScheduleId(uint256 scheduleId);

/// @dev Thrown when a schedule is invalid (violates duration/cliff constraints)
error InvalidSchedule(uint256 scheduleId);

/// @dev Thrown when an allocation is invalid (zero address or zero amount)
error InvalidAllocation(uint256 index);

/// @dev Thrown when the specified balance limit timestamp is in the past
error InvalidBalanceLimitTimestamp(uint256 specified, uint256 current);

/// @dev Thrown when the specified balance limit wad is invalid
error InvalidBalanceLimit(uint256 limit);

/// @dev Thrown when an address's balance exceeds the balance limit
error BalanceLimitExceeded(uint256 balance, uint256 limit);

/// @dev Thrown when the requested amount is greater than the available amount
error InsufficientReleasableAmount(uint256 available, uint256 requested);

/// @dev Thrown when trying to premint more than the maximum allowed per address
error MaxPreMintPerAddressExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when trying to premint more than the maximum allowed in total
error MaxTotalPreMintExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when trying to mint more than the maximum allowed in total
error MaxTotalVestedExceeded(uint256 amount, uint256 limit);

/// @dev Thrown when trying to set the mint rate to a value higher than the maximum allowed
error MaxYearlyMintRateExceeded(uint256 amount, uint256 limit);

/// @dev Max amount of tokens that can be pre-minted per address (% expressed in WAD)
uint256 constant MAX_PRE_MINT_PER_ADDRESS_WAD = 0.8 ether;

/// @dev Max amount of tokens that can be pre-minted in total (% expressed in WAD)
uint256 constant MAX_TOTAL_PRE_MINT_WAD = 0.8 ether;

/// @dev Maximum amount of tokens that can be minted in a year (% expressed in WAD)
uint256 constant MAX_YEARLY_MINT_RATE_WAD = 0.02 ether;

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

/**
 * @notice Vesting data for a specific address
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

/// @notice Emitted when the token URI is updated
event UpdateTokenURI(string tokenURI);

/// @notice Emitted when the yearly mint rate is updated
event UpdateMintRate(uint256 newMintRate);

/// @notice Emitted when the balance limit is disabled
event BalanceLimitDisabled(bool expired);

/**
 * @title DopplerERC20 V1.0.0
 * @author Whetstone Research
 * @notice Clonable ERC20 token with multi-schedule vesting, inflation, pool lock,
 *         votes, max balance limit, and Permit2 support
 * @dev This contract is designed to be cloned using the ERC1167 minimal proxy pattern
 * @custom:security-contact security@whetstone.cc
 */
contract DopplerERC20V1 is ERC20, Initializable, Ownable, ERC20Votes {
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

    /// @notice Controller address (can disable the balance limit)
    address public controller;

    /// @notice Address of the liquidity pool
    address public pool;

    /// @notice Whether the pool can receive tokens (unlocked) or not
    bool public isPoolLocked;

    /// @notice Whether the balance limit is active or not
    bool public isBalanceLimitActive;

    /// @notice Balance limit end timestamp (in seconds)
    uint48 public balanceLimitEnd;

    /// @notice Maximum balance limit
    uint256 public maxBalanceLimit;

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

    /// @notice Whether an address is excluded from the balance limit
    mapping(address account => bool excluded) public isExcludedFromBalanceLimit;

    modifier onlyController() {
        require(msg.sender == controller, Unauthorized());
        _;
    }

    constructor() {
        _disableInitializers();
    }

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
     * @param maxBalanceLimit_ Maximum balance limit
     * @param balanceLimitEnd_ Balance limit end timestamp
     * @param controller_ Controller address (optional, excluding it prevents disabling the balance limit earlier)
     * @param excludedFromBalanceLimit Array of addresses to exclude from the balance limit
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
        string memory tokenURI_,
        uint256 maxBalanceLimit_,
        uint48 balanceLimitEnd_,
        address controller_,
        address[] memory excludedFromBalanceLimit
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

        if (balanceLimitEnd_ > 0 || maxBalanceLimit_ > 0) {
            require(maxBalanceLimit_ > 0 && maxBalanceLimit_ < initialSupply, InvalidBalanceLimit(maxBalanceLimit_));
            require(balanceLimitEnd_ > block.timestamp, InvalidBalanceLimitTimestamp(balanceLimitEnd_, block.timestamp));

            maxBalanceLimit = maxBalanceLimit_;
            balanceLimitEnd = balanceLimitEnd_;
            controller = controller_;
            isBalanceLimitActive = true;
            isExcludedFromBalanceLimit[owner_] = true;
            isExcludedFromBalanceLimit[recipient] = true;

            uint256 excludedLength = excludedFromBalanceLimit.length;
            for (uint256 i; i < excludedLength; ++i) {
                isExcludedFromBalanceLimit[excludedFromBalanceLimit[i]] = true;
            }
        }

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
            uint256 totalAllocated = totalAllocatedOf[beneficiary];
            require(
                totalAllocated <= maxPreMintPerAddress,
                MaxPreMintPerAddressExceeded(totalAllocated, maxPreMintPerAddress)
            );

            // Update vesting data and exclude from balance limit
            vestingOf[beneficiary][scheduleId].totalAmount += amount;
            isExcludedFromBalanceLimit[beneficiary] = true;

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
     * @notice Locks the pool, preventing it from receiving tokens, and excludes it from the balance limit
     * @param pool_ Address of the pool to lock
     */
    function lockPool(address pool_) external onlyOwner {
        pool = pool_;
        isPoolLocked = true;
        isExcludedFromBalanceLimit[pool_] = true;
    }

    /// @notice Unlocks the pool, allowing it to receive tokens
    function unlockPool() external onlyOwner {
        isPoolLocked = false;
        currentYearStart = lastMintTimestamp = block.timestamp;
    }

    /* ------------------------------------------------------------------------- */
    /*                                 Controller                                */
    /* ------------------------------------------------------------------------- */

    /// @notice Permanently disables the balance limit
    /// @dev Only callable by the controller, which is set during initialization
    ///      If the controller was not set, the balance limit cannot be disabled early
    function disableBalanceLimit() external onlyController {
        require(isBalanceLimitActive, BalanceLimitNotActive());
        isBalanceLimitActive = false;
        emit BalanceLimitDisabled(false);
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
     * @dev Use 0 for `amount` to release total available amount
     * @param scheduleId Schedule ID to release from
     * @param amount Amount of tokens to release
     */
    function release(uint256 scheduleId, uint256 amount) external {
        _releaseFor(msg.sender, scheduleId, amount);
    }

    /**
     * @notice Releases all available vested tokens across all schedules for the caller
     * @dev Use 0 for `amount` to release total available amount
     * @param amount Amount of tokens to release
     */
    function release(uint256 amount) external {
        _releaseAllFor(msg.sender, amount);
    }

    /**
     * @notice Releases available vested tokens for a beneficiary under a specific schedule
     * @dev Anyone can call; tokens always go to the beneficiary; use 0 for `amount` to release total available amount
     * @param beneficiary Bneficiary address
     * @param scheduleId Schedule ID to release from
     * @param amount Amount of tokens to release
     */
    function releaseFor(address beneficiary, uint256 scheduleId, uint256 amount) external {
        _releaseFor(beneficiary, scheduleId, amount);
    }

    /**
     * @notice Releases all available vested tokens for a beneficiary across all schedules
     * @dev Anyone can call; tokens always go to the beneficiary; use 0 for `amount` to release total available amount
     * @param beneficiary Beneficiary address
     * @param amount Amount of tokens to release
     */
    function releaseFor(address beneficiary, uint256 amount) external {
        _releaseAllFor(beneficiary, amount);
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
     * @param amount Amount of tokens to release
     */
    function _releaseFor(address beneficiary, uint256 scheduleId, uint256 amount) internal {
        require(scheduleId < vestingSchedules.length, UnknownScheduleId(scheduleId));

        uint256 available = _available(beneficiary, scheduleId);
        require(available > 0, NoReleasableAmount());
        if (amount > 0) require(available >= amount, InsufficientReleasableAmount(available, amount));
        else amount = available;

        vestingOf[beneficiary][scheduleId].releasedAmount += amount;
        _transfer(address(this), beneficiary, amount);
        emit TokensReleased(beneficiary, scheduleId, amount);
    }

    /**
     * @dev Releases tokens for a beneficiary across all their schedules
     * @param beneficiary Beneficiary address
     * @param amount Amount of tokens to release
     */
    function _releaseAllFor(address beneficiary, uint256 amount) internal {
        uint256[] memory ids = _scheduleIdsOf[beneficiary];
        uint256 length = ids.length;

        // First pass: compute available amounts and total, stop if non-zero amount is reached
        uint256[] memory amounts = new uint256[](length);
        uint256 total;
        for (uint256 i; i < length; i++) {
            amounts[i] = _available(beneficiary, ids[i]);
            total += amounts[i];
            if (amount > 0 && total >= amount) {
                total = amount;
                break;
            }
        }

        // Ensure a requested amount is available
        require(total >= amount, InsufficientReleasableAmount(total, amount));
        amount = total;

        // Ensure a non-zero amount is available
        require(amount > 0, NoReleasableAmount());

        // Second pass: update state and emit events
        for (uint256 i; i < length; i++) {
            if (amounts[i] > 0) {
                uint256 released = amounts[i] > total ? total : amounts[i];
                unchecked {
                    vestingOf[beneficiary][ids[i]].releasedAmount += released;
                    total -= released;
                }

                emit TokensReleased(beneficiary, ids[i], released);
                if (total == 0) break;
            }
        }

        // Single transfer
        _transfer(address(this), beneficiary, amount);
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
    function _beforeTokenTransfer(address from, address to, uint256 value) internal override {
        if (to == pool && isPoolLocked) revert PoolLocked();
        if (isBalanceLimitActive) {
            // Exclude self transfers, burns, and vesting mints prior to checking exclusions
            if (from != to && to != address(0) && to != address(this)) {
                if (!isExcludedFromBalanceLimit[to]) {
                    if (block.timestamp < balanceLimitEnd) {
                        uint256 newBalance = balanceOf(to) + value;
                        require(newBalance <= maxBalanceLimit, BalanceLimitExceeded(newBalance, maxBalanceLimit));
                    } else {
                        // Lazily disable balance limit on first post expiration transfer
                        isBalanceLimitActive = false;
                        emit BalanceLimitDisabled(true);
                    }
                }
            }
        }
    }

    /// @inheritdoc ERC20
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return true;
    }

    /// @inheritdoc ERC20Votes
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20Votes, ERC20) {
        super._afterTokenTransfer(from, to, amount);
    }

    /// @inheritdoc Ownable
    function _setOwner(address newOwner) internal override {
        // Exclude new owners from balance limit to prevent inflation mints from reverting
        // This is only relevant if the balance limit is still enabled during/after migration
        if (balanceLimitEnd > block.timestamp) isExcludedFromBalanceLimit[newOwner] = true;
        super._setOwner(newOwner);
    }
}
