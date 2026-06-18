### Deployment

The supported top-level deployment entry point is [`script/DeployDoppler.s.sol`](../script/DeployDoppler.s.sol). It deploys or reuses the versioned contracts controlled by [`script/utils/Versions.sol`](../script/utils/Versions.sol), writes deployment outputs back to [`deployments.config.toml`](../deployments.config.toml) during broadcast runs, and can be rerun after bumping only the versions that need new deployments. Individual scripts in [`script/deploy`](../script/deploy) can still be run directly when deploying one contract at a time.

The current target chains are:

| Chain        | Chain ID | Top-level script                 | Testnet |
| ------------ | -------: | -------------------------------- | ------- |
| Ethereum     |      `1` | `DeployDopplerScriptEthereum`    | `false` |
| Monad        |    `143` | `DeployDopplerScriptMonad`       | `false` |
| Base         |   `8453` | `DeployDopplerScriptBase`        | `false` |
| Base Sepolia |  `84532` | `DeployDopplerScriptBaseSepolia` | `true`  |

To add another target chain, add the chain ID to [`script/utils/ChainIds.sol`](../script/utils/ChainIds.sol), add an explicit wrapper contract in `DeployDoppler.s.sol` that calls `_setUpChain(chainId, isTestnet)`, add a complete chain section to `deployments.config.toml`, and configure the target RPC in both [`foundry.toml`](../foundry.toml) and `deployments.config.toml`.

Deployment configuration:

RPC configuration has one environment value and two repository references:

- `.env`: set the actual RPC URL environment variable, for example `BASE_MAINNET_RPC_URL=...`.
- `[rpc_endpoints]` in `foundry.toml`: map a Foundry RPC alias to that environment variable, for example `base = "${BASE_MAINNET_RPC_URL}"`. Use this alias for CLI commands that pass `--rpc-url <foundry-rpc-alias>`.
- `[chain] endpoint_url` in `deployments.config.toml`: reference the same environment variable for that chain, for example `[8453] endpoint_url = "${BASE_MAINNET_RPC_URL}"`. Chain-specific top-level wrappers use this value when selecting their fork.

Keep the `foundry.toml` alias and the `deployments.config.toml` `endpoint_url` reference aligned for each chain so bootstrap, standalone, and aggregate deployment commands all run against the same RPC.

Required chain config in `deployments.config.toml`:

- `[chain] endpoint_url`: RPC endpoint environment reference used by the chain-specific top-level deployment wrappers.
- `[chain.bool] is_testnet`: `true` only for chains that should deploy `AirlockMultisigTestnet` before `Airlock`.
- `[chain.address] deployer_owner`: owner for the `DopplerCreateXDeployer` bootstrap deployment.
- `[chain.address] protocol_deployer`: populated after `DeployDopplerCreateXDeployerScript` is broadcast.
- `[chain.address] airlock_multisig`: required for non-testnets. Testnets deploy and write this through `DeployAirlockMultisigTestnet`.
- `[chain.address] uniswap_v4_pool_manager`
- `[chain.address] uniswap_v3_factory`
- `[chain.address] uniswap_v2_factory`
- `[chain.address] weth`
- `[chain.address] quoter_v2`
- `[chain.address] quoter_v4`
- `[chain.address] universal_router`
- `[chain.address] uniswap_v4_state_view`

Deployment flow:

1. Configure the target chain RPC in all three places: set the environment variable in `.env`, map it under `[rpc_endpoints]` in `foundry.toml`, and reference it as `[chain] endpoint_url` in `deployments.config.toml`. Add a `DeployDopplerScript` wrapper if this is a new supported chain. If deploying new protocol versions on an existing chain, update the relevant constants in `Versions.sol`.
2. Configure `salt` and `expectedAddress` in `DeployDopplerCreateXDeployerScript`, set `deployer_owner`, then broadcast the bootstrap deployer script. A successful broadcast writes `protocol_deployer` to the active chain config.

   ```shell
   forge script script/DeployDopplerCreateXDeployer.s.sol:DeployDopplerCreateXDeployerScript --rpc-url <foundry-rpc-alias> --broadcast
   ```

3. Authorize the account that will broadcast `DeployDopplerScript`. The `protocol_deployer` owner is already authorized; otherwise the owner or an admin should call `addDeployers(address[])` on `DopplerCreateXDeployer`.

   ```shell
   cast send <protocol_deployer> "addDeployers(address[])" "[<broadcaster>]" --rpc-url <rpc-url> --private-key <owner-or-admin-private-key>
   ```

4. Broadcast the top-level deployment script for the target chain. The chain-specific wrapper selects the configured fork for its chain ID.

   ```shell
   forge script script/DeployDoppler.s.sol:DeployDopplerScriptBase --broadcast
   ```

For standalone contract deployments, run the specific script from `script/deploy` with the target chain RPC context after `protocol_deployer` is configured and the broadcaster is authorized. Individual deploy scripts also expose chain-specific wrappers named like `<DeployScriptName>Ethereum`, `<DeployScriptName>Monad`, `<DeployScriptName>Base`, and `<DeployScriptName>BaseSepolia`, which select the configured RPC endpoint internally. `DeployAirlockMultisigTestnetScript` is testnet-only and exposes only `DeployAirlockMultisigTestnetScriptBaseSepolia`.

The same scripts can be run from the **Deploy Contracts** GitHub Action. Enter the Solidity script contract name, such as `DeployDopplerScriptBase`, and leave **Broadcast (simulate if unchecked)** disabled for a dry-run simulation. The action resolves the matching foundry script, derives the deployer address from the `DEPLOYER_PRIVATE_KEY` repository secret, and passes both `--private-key` and `--sender` so default `vm.startBroadcast()` calls use the deployer account in simulations and broadcasts. Chain-specific wrappers use the RPC environment variable configured in `deployments.config.toml`, so the matching RPC URL secret must exist in GitHub; standalone scripts that call `_loadConfigForCurrentChain()` should use the optional RPC alias/URL input. After broadcast runs, the action runs `make generate-history` and opens a pull request for any changed broadcast logs, `deployments.config.toml`, and generated deployment docs using GitHub's built-in `GITHUB_TOKEN`.
