// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@v4-core/types/PoolId.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { DERC20 } from "src/DERC20.sol";
import { Doppler } from "src/Doppler.sol";
import { MigrationMath } from "src/libraries/MigrationMath.sol";

/// @dev Thrown when trying to buy more than the per-address buy limit amount
error BuyLimitExceeded();

/// @dev Thrown when an address tries to buy tokens without having set its country code during the buy limit period
error NoCountryCode();

/// @dev Thrown when trying to set a malformed ISO 3166-1 code. Not all cases are verified, only basic 2-letter format.
error MalformedCountryCode();

struct PoolInfo {
    bool isToken0;
    PoolId poolId;
}

/// @notice DERC20 token with a temporary per-address purchase limit from a predefined address
contract DERC20BuyLimit is DERC20, ImmutableAirlock {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Address of the buy-limited pool manager, transfers from it are subject to buy limits
    IPoolManager public immutable buyLimitedPoolManager;

    /// @notice Timestamp of the end of the buy limit period
    uint256 public immutable buyLimitEnd;

    /// @notice Maximum amount of numeraire that can be spent on tokens by a single address during the buy limit period
    uint256 public immutable spendLimitAmount;

    /// @notice Amount of numeraire spent on tokens by each address during the buy limit period
    mapping(address => uint256) public getSpentAmounts;

    /// @notice ISO 3166-1 alpha-2 two-letter country code. Required for each address during the buy limit period
    mapping(address => string) public getCountryCode;

    /// @notice Pool information necessary to enforce buy limits, delayed initialization via getBuyLimitPoolInfo
    PoolInfo internal _buyLimitPoolInfo;

    /**
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialSupply Initial supply of the token
     * @param recipient Address receiving the initial supply
     * @param owner_ Address receiving the ownership of the token
     * @param yearlyMintRate_ Maximum inflation rate of token in a year
     * @param vestingDuration_ Duration of the vesting period (in seconds)
     * @param recipients_ Array of addresses receiving vested tokens
     * @param amounts_ Array of amounts of tokens to be vested
     * @param tokenURI_ Uniform Resource Identifier (URI)
     * @param buyLimitedPoolManager_ Address of the buy limited seller
     * @param buyLimitEnd_ Timestamp of the end of the buy limit period
     * @param spendLimitAmount_ Maximum amount of numeraire that can be spent on tokens by a single address during the buy limit period
     * @param airlock_ Address of the Airlock contract
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
        string memory tokenURI_,
        IPoolManager buyLimitedPoolManager_,
        uint256 buyLimitEnd_,
        uint256 spendLimitAmount_,
        address airlock_
    )
        DERC20(
            name_,
            symbol_,
            initialSupply,
            recipient,
            owner_,
            yearlyMintRate_,
            vestingDuration_,
            recipients_,
            amounts_,
            tokenURI_
        )
        ImmutableAirlock(airlock_)
    {
        buyLimitedPoolManager = buyLimitedPoolManager_;
        buyLimitEnd = buyLimitEnd_;
        spendLimitAmount = spendLimitAmount_;
    }

    function _isValidCountryCodeLetter(
        bytes1 letter
    ) internal pure returns (bool) {
        return letter >= "A" && letter <= "Z";
    }

    function setCountryCode(
        string calldata countryCode
    ) external {
        bytes calldata countryCodeBytes = bytes(countryCode);
        require(
            countryCodeBytes.length == 2 && _isValidCountryCodeLetter(countryCodeBytes[0])
                && _isValidCountryCodeLetter(countryCodeBytes[1]),
            MalformedCountryCode()
        );
        getCountryCode[msg.sender] = countryCode;
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(DERC20) {
        _enforceBuyLimit(from, to, amount);
        super._update(from, to, amount);
    }

    function _enforceBuyLimit(
        address from,
        address to,
        uint256 tokenAmount
    ) internal {
        if (block.timestamp < buyLimitEnd && from == address(buyLimitedPoolManager)) {
            // Country code of buyer must be set
            require(bytes(getCountryCode[to]).length == 2, NoCountryCode());

            // Get pool info
            (bool isToken0, PoolId poolId) = getBuyLimitPoolInfo();

            // Get numeraire amount (limit uses numeraire amounts, not token amounts)
            (uint160 sqrtPrice,,,) = buyLimitedPoolManager.getSlot0(poolId);
            uint256 numeraireAmount = _getQuoteAtPrice(isToken0, tokenAmount, sqrtPrice);

            // Resulting spent amount must stay within buy limit
            getSpentAmounts[to] += numeraireAmount;
            require(getSpentAmounts[to] <= spendLimitAmount, BuyLimitExceeded());
        }
    }

    function _getQuoteAtPrice(
        bool isToken0,
        uint256 amount,
        uint160 sqrtPrice
    ) internal pure returns (uint256) {
        uint256 balance0 = isToken0 ? amount : 0;
        uint256 balance1 = isToken0 ? 0 : amount;
        (uint256 depositAmount0, uint256 depositAmount1) =
            MigrationMath.computeDepositAmounts(balance0, balance1, sqrtPrice);
        return isToken0 ? depositAmount1 : depositAmount0;
    }

    function getBuyLimitPoolInfo() public returns (bool isToken0, PoolId poolId) {
        // The first time pool info is accessed, save it to avoid the many expensive storage reads
        if (PoolId.unwrap(_buyLimitPoolInfo.poolId) == "") {
            (,,,,, address pool,,,,) = airlock.getAssetData(address(this));
            Doppler doppler = Doppler(payable(pool));
            isToken0 = doppler.isToken0();
            (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = doppler.poolKey();
            poolId = PoolKey(currency0, currency1, fee, tickSpacing, hooks).toId();

            _buyLimitPoolInfo = PoolInfo(isToken0, poolId);
            return (isToken0, poolId);
        } else {
            return (_buyLimitPoolInfo.isToken0, _buyLimitPoolInfo.poolId);
        }
    }
}
