// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { AirlockMultisig } from "test/shared/AirlockMultisig.sol";
import { ModuleState } from "src/Airlock.sol";

/// @notice Small helper CLI to set module states, for testing purposes.
/// This CLI assumes the `msg.sender` is an approved signer of the AirlockMultisig.
contract SetModuleScript is Script {
    function run() public {
        try vm.promptAddress("Please enter the address of the AirlockMultisig") returns (address multisig) {
            try vm.promptAddress("Please enter the address of the module to set") returns (address module) {
                try vm.promptUint(
                    "Please enter the module state:\n- 1 - TokenFactory\n- 2 - GovernanceFactory\n- 3 - PoolInitializer\n- 4 - LiquidityMigrator"
                ) returns (uint256 state) {
                    require(state <= 4, "Invalid module state");

                    vm.startBroadcast();
                    AirlockMultisig multisigContract = AirlockMultisig(multisig);
                    multisigContract.setModuleState(module, ModuleState(state));
                    vm.stopBroadcast();

                    console.log("Module %s set to state %s!", module, state);
                } catch {
                    revert("Module state is required and must be a valid uint8.");
                }
            } catch {
                revert("Module address is required.");
            }
        } catch {
            revert("AirlockMultisig address is required.");
        }
    }
}
