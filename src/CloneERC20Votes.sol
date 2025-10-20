// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ERC20Votes } from "solady/tokens/ERC20Votes.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { CloneERC20 } from "src/CloneERC20.sol";

/**
 * @title CloneERC20Votes
 * @author Whetstone Research
 * @notice ERC20 token with permit, voting, inflationary minting, and vesting features
 * @dev This contract is designed to be cloned using the ERC1167 minimal proxy pattern
 * @custom:security-contact security@whetstone.cc
 */
contract CloneERC20Votes is ERC20Votes, CloneERC20 {
    /// @inheritdoc ERC20Votes
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20Votes, ERC20) {
        super._afterTokenTransfer(from, to, amount);
    }

    /// @inheritdoc ERC20
    function _givePermit2InfiniteAllowance() internal pure override(CloneERC20, ERC20) returns (bool) {
        return false;
    }
}
