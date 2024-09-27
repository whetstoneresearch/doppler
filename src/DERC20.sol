/// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {ERC20Votes} from "openzeppelin/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ERC20Permit} from "openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import {Nonces} from "openzeppelin/utils/Nonces.sol";

/**
 * TODO:
 * - Add mint cap: bounded annual max inflation which can only go down
 */
error MintingNotStartedYet();

contract DERC20 is ERC20Votes, ERC20Permit, Ownable {
    uint256 public feeOnTransfer;
    mapping(address => bool) public isExemptFromFees;
    address public feeCollector;

    uint256 public immutable mintStartDate;
    uint256 public immutable yearlyMintCap;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address recipient,
        uint256 feeOnTransfer_,
        address[] memory exemptFromFees,
        address feeCollector_,
        address owner_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        _mint(recipient, totalSupply_);
        feeOnTransfer = feeOnTransfer_;

        for (uint256 i = 0; i < exemptFromFees.length; i++) {
            isExemptFromFees[exemptFromFees[i]] = true;
        }

        feeCollector = feeCollector_;
        isExemptFromFees[feeCollector_] = true; // Just in case

        mintStartDate = block.timestamp + 365 days;
    }

    function mint(address to, uint256 value) external onlyOwner {
        require(block.timestamp >= mintStartDate, MintingNotStartedYet());
        _mint(to, value);
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function _update(address from, address to, uint256 value) internal virtual override(ERC20, ERC20Votes) {
        super._update(from, to, value);

        // TODO: Check when should we charge / NOT charge the fee?
        if (feeOnTransfer > 0 && !isExemptFromFees[from] && !isExemptFromFees[to]) {
            uint256 fee = feeOnTransfer * value / 10_000;
            _transfer(to, feeCollector, fee);
        }
    }
}
