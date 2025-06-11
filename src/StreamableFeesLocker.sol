// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPositionManager } from "@v4-periphery/interfaces/IPositionManager.sol";
import { Actions } from "@v4-periphery/libraries/Actions.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { ERC721, ERC721TokenReceiver } from "@solmate/tokens/ERC721.sol";

/// @notice Data structure for beneficiary information
/// @param beneficiary Address of the beneficiary
/// @param shares Share of fees allocated to this beneficiary (in WAD)
struct BeneficiaryData {
    address beneficiary;
    uint64 shares;
}

/// @notice Data structure for position information
/// @param beneficiaries Array of beneficiaries and their shares
/// @param startDate Timestamp when the position was locked
/// @param isUnlocked Whether the position has been unlocked
/// @param recipient Address that will receive the NFT after unlocking
struct PositionData {
    BeneficiaryData[] beneficiaries;
    uint64 startDate;
    bool isUnlocked;
    address recipient;
}

/// @title StreamableFeesLocker
/// @notice A contract that manages fee streaming for Uniswap V4 positions
/// @dev Allows locking positions for a specified duration and streaming fees to multiple beneficiaries
/// @dev Uses a time-based distribution mechanism to ensure fair fee distribution
contract StreamableFeesLocker is ERC721TokenReceiver {
    /// @notice Emitted when a position is locked
    /// @param tokenId The ID of the locked position
    /// @param beneficiaries Array of beneficiaries and their shares
    /// @param unlockDate Timestamp when the position will be unlocked
    event Lock(uint256 indexed tokenId, BeneficiaryData[] beneficiaries, uint256 unlockDate);

    /// @notice Emitted when a position is unlocked
    /// @param tokenId The ID of the unlocked position
    /// @param recipient Address that received the NFT
    event Unlock(uint256 indexed tokenId, address recipient);

    /// @notice Emitted when fees are distributed to a beneficiary
    /// @param tokenId The ID of the position
    /// @param amount0 Amount of token0 distributed
    /// @param amount1 Amount of token1 distributed
    event DistributeFees(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    /// @notice Emitted when fees are released to a beneficiary
    /// @param tokenId The ID of the position
    /// @param beneficiary Address that received the fees
    /// @param amount0 Amount of token0 released
    /// @param amount1 Amount of token1 released
    event Release(uint256 indexed tokenId, address beneficiary, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a beneficiary is updated
    /// @param tokenId The ID of the position
    /// @param oldBeneficiary Previous beneficiary address
    /// @param newBeneficiary New beneficiary address
    event UpdateBeneficiary(uint256 indexed tokenId, address oldBeneficiary, address newBeneficiary);

    /// @notice WAD constant for precise decimal calculations
    uint256 constant WAD = 1e18;

    /// @notice Duration for which positions are locked
    uint256 constant LOCK_DURATION = 30 days;

    /// @notice Address of the Uniswap V4 position manager
    IPositionManager public immutable positionManager;

    /// @notice Mapping of token IDs to their position data
    mapping(uint256 tokenId => PositionData) public positions;

    /// @notice Mapping of beneficiary addresses to their claimable balances for each currency
    mapping(address beneficiary => mapping(Currency currency => uint256 releasableBalance)) public beneficiariesClaims;

    /// @notice Mapping of currency balances in the contract
    mapping(Currency currency => uint256 balanceOfSelf) public currencyBalances;

    /// @notice Constructor
    /// @param positionManager_ Address of the Uniswap V4 position manager
    constructor(
        IPositionManager positionManager_
    ) {
        positionManager = positionManager_;
    }

    /// @notice Modifier to restrict function access to the position manager
    modifier onlyPositionManager() {
        if (msg.sender != address(positionManager)) {
            revert("StreamableFeesLocker: ONLY_POSITION_MANAGER");
        }
        _;
    }

    /// @notice Handles incoming ERC721 tokens and initializes position data
    /// @param tokenId ID of the token being transferred
    /// @param positionData Encoded data containing recipient and beneficiaries
    /// @return bytes4 The ERC721 receiver selector
    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata positionData
    ) external override onlyPositionManager returns (bytes4) {
        (address recipient, BeneficiaryData[] memory beneficiaries) =
            abi.decode(positionData, (address, BeneficiaryData[]));
        require(beneficiaries.length > 0, "StreamableFeesLocker: ZERO_BENEFICIARIES");
        require(recipient != address(0), "StreamableFeesLocker: RECIPIENT_CANNOT_BE_ZERO_ADDRESS");

        uint256 totalShares;
        for (uint256 i; i != beneficiaries.length; ++i) {
            require(
                beneficiaries[i].beneficiary != address(0), "StreamableFeesLocker: BENEFICIARY_CANNOT_BE_ZERO_ADDRESS"
            );
            require(beneficiaries[i].shares > 0, "StreamableFeesLocker: SHARES_MUST_BE_GREATER_THAN_ZERO");

            totalShares += beneficiaries[i].shares;
        }

        require(totalShares == WAD, "StreamableFeesLocker: TOTAL_SHARES_NOT_EQUAL_TO_WAD");

        positions[tokenId] = PositionData({
            beneficiaries: beneficiaries,
            startDate: uint64(block.timestamp),
            isUnlocked: false,
            recipient: recipient
        });

        emit Lock(tokenId, beneficiaries, block.timestamp + LOCK_DURATION);

        return ERC721TokenReceiver.onERC721Received.selector;
    }

    /// @notice Accrues and distributes fees for a position
    /// @param tokenId ID of the position to accrue fees for
    function distributeFees(
        uint256 tokenId
    ) external {
        PositionData memory position = positions[tokenId];
        require(position.startDate != 0, "StreamableFeesLocker: POSITION_NOT_FOUND");
        require(position.isUnlocked != true, "StreamableFeesLocker: POSITION_ALREADY_UNLOCKED");

        // Get pool info
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);

        // Get the amount of fees to claim
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, new bytes(0));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        BeneficiaryData[] memory beneficiaries = position.beneficiaries;

        (uint256 currency0ToDistribute, uint256 currency1ToDistribute) = _updateCurrencyBalances(position, poolKey);

        uint256 amount0Distributed;
        uint256 amount1Distributed;
        address beneficiary;
        for (uint256 i; i < beneficiaries.length; ++i) {
            beneficiary = beneficiaries[i].beneficiary;
            uint256 shares = beneficiaries[i].shares;

            // Calculate share of fees for this beneficiary
            uint256 amount0 = currency0ToDistribute * shares / WAD;
            uint256 amount1 = currency1ToDistribute * shares / WAD;

            _distributeFees(beneficiary, poolKey, amount0, amount1);

            amount0Distributed += amount0;
            amount1Distributed += amount1;
        }

        // Distribute the remaining fees to the last beneficiary
        uint256 amount0Remaining =
            currency0ToDistribute > amount0Distributed ? currency0ToDistribute - amount0Distributed : 0;
        uint256 amount1Remaining =
            currency1ToDistribute > amount1Distributed ? currency1ToDistribute - amount1Distributed : 0;
        _distributeFees(beneficiary, poolKey, amount0Remaining, amount1Remaining);

        if (block.timestamp >= position.startDate + LOCK_DURATION) {
            position.isUnlocked = true;

            // Transfer the position to the recipient
            ERC721(address(positionManager)).safeTransferFrom(address(this), position.recipient, tokenId, new bytes(0));

            emit Unlock(tokenId, position.recipient);
        }

        // Update the position in storage
        positions[tokenId] = position;

        emit DistributeFees(tokenId, currency0ToDistribute, currency1ToDistribute);
    }

    /// @notice Releases accrued fees to the caller
    /// @param tokenId ID of the position to release fees from
    function releaseFees(
        uint256 tokenId
    ) external {
        // Check if position exists
        PositionData memory position = positions[tokenId];
        require(position.startDate != 0, "StreamableFeesLocker: POSITION_NOT_FOUND");

        // Check if sender is a beneficiary
        bool isBeneficiary = false;
        for (uint256 i = 0; i < position.beneficiaries.length; i++) {
            if (position.beneficiaries[i].beneficiary == msg.sender) {
                isBeneficiary = true;
                break;
            }
        }
        require(isBeneficiary, "StreamableFeesLocker: NOT_BENEFICIARY");

        _releaseFees(tokenId, msg.sender);
    }

    /// @notice Updates currency balances and calculates distributable amounts
    /// @param position Current position data
    /// @param poolKey Pool information
    /// @return amount0ToDistribute Amount of token0 to distribute
    /// @return amount1ToDistribute Amount of token1 to distribute
    function _updateCurrencyBalances(
        PositionData memory position,
        PoolKey memory poolKey
    ) internal returns (uint256 amount0ToDistribute, uint256 amount1ToDistribute) {
        // Calculate the amount of fees to distribute
        amount0ToDistribute = poolKey.currency0.balanceOfSelf() - currencyBalances[poolKey.currency0];
        amount1ToDistribute = poolKey.currency1.balanceOfSelf() - currencyBalances[poolKey.currency1];

        // Update the global balance
        currencyBalances[poolKey.currency0] += amount0ToDistribute;
        currencyBalances[poolKey.currency1] += amount1ToDistribute;
    }

    /// @notice Distributes fees to a beneficiary
    /// @param beneficiary Address to distribute fees to
    /// @param poolKey Pool information
    /// @param amount0 Amount of token0 to distribute
    /// @param amount1 Amount of token1 to distribute
    function _distributeFees(address beneficiary, PoolKey memory poolKey, uint256 amount0, uint256 amount1) internal {
        beneficiariesClaims[beneficiary][poolKey.currency0] += amount0;
        beneficiariesClaims[beneficiary][poolKey.currency1] += amount1;
    }

    /// @notice Releases fees to a beneficiary
    /// @param tokenId ID of the position
    /// @param beneficiary Address to release fees to
    function _releaseFees(uint256 tokenId, address beneficiary) internal {
        // Get pool info
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);

        // Get the amount of fees to release
        uint256 amount0ToRelease = beneficiariesClaims[beneficiary][poolKey.currency0];
        uint256 amount1ToRelease = beneficiariesClaims[beneficiary][poolKey.currency1];

        // Release the fees
        poolKey.currency0.transfer(beneficiary, amount0ToRelease);
        poolKey.currency1.transfer(beneficiary, amount1ToRelease);

        // Reset the claims
        beneficiariesClaims[beneficiary][poolKey.currency0] = 0;
        beneficiariesClaims[beneficiary][poolKey.currency1] = 0;

        // Update currency balances
        currencyBalances[poolKey.currency0] -= amount0ToRelease;
        currencyBalances[poolKey.currency1] -= amount1ToRelease;

        emit Release(tokenId, beneficiary, amount0ToRelease, amount1ToRelease);
    }

    /// @notice Updates the beneficiary address for a position
    /// @param tokenId ID of the position
    /// @param newBeneficiary New beneficiary address
    function updateBeneficiary(uint256 tokenId, address newBeneficiary) external {
        // Get position data
        PositionData memory position = positions[tokenId];
        require(position.startDate != 0, "StreamableFeesLocker: POSITION_NOT_FOUND");
        require(newBeneficiary != address(0), "StreamableFeesLocker: NEW_BENEFICIARY_CANNOT_BE_ZERO_ADDRESS");

        // Get the index of the beneficiary to transfer ownership to `newBeneficiary`
        uint256 length = position.beneficiaries.length;
        bool found = false;
        for (uint256 i; i != length; ++i) {
            if (position.beneficiaries[i].beneficiary == msg.sender) {
                // Release fees for the old beneficiary
                _releaseFees(tokenId, msg.sender);

                // Update the beneficiary
                position.beneficiaries[i].beneficiary = newBeneficiary;
                found = true;
                break;
            }
        }
        require(found, "StreamableFeesLocker: NOT_BENEFICIARY");

        // Update the position data
        positions[tokenId] = position;

        emit UpdateBeneficiary(tokenId, msg.sender, newBeneficiary);
    }
}
