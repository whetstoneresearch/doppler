// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IBundleCallback, CreateResult, Transfer, Call} from "src/interfaces/IBundleCallback.sol";
import {LaunchVault} from "src/LaunchVault.sol";

/// @notice Callback that deposits prebuy tokens to LaunchVault
/// @dev Uses push model: tokens are transferred directly to vault, then recorded
contract PrebuyToVaultCallback is IBundleCallback {
    address public immutable launchVault;

    constructor(address launchVault_) {
        launchVault = launchVault_;
    }

    /// @notice Plan transfers and calls to deposit prebuy to the vault
    /// @param result The result of the bundle creation
    /// @param data Encoded (beneficiary, prebuyAmount)
    /// @return transfers Array with one transfer of the asset to the vault (PUSH model)
    /// @return calls Array with one call to record the deposit in vault
    /// @dev Flow: 1) Bundler transfers tokens to vault, 2) Bundler calls vault to record
    function plan(CreateResult calldata result, bytes calldata data)
        external
        view
        returns (Transfer[] memory transfers, Call[] memory calls)
    {
        (address beneficiary, uint256 prebuyAmount) = abi.decode(data, (address, uint256));

        // STEP 1: Transfer asset from bundler to vault (PUSH model - no approval needed)
        transfers = new Transfer[](1);
        transfers[0] = Transfer({
            token: result.asset,
            to: launchVault,
            amount: prebuyAmount
        });

        // STEP 2: Call vault to record the deposit
        // Vault verifies it received the tokens before recording
        calls = new Call[](1);
        calls[0] = Call({
            target: launchVault,
            value: 0,
            data: abi.encodeWithSelector(
                LaunchVault.depositPrebuy.selector,
                result.asset,
                beneficiary,
                prebuyAmount
            )
        });
    }
}
