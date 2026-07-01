### Deployment

The supported top-level protocol deployment entry point is
[`script/DeployDoppler.s.sol`](../script/DeployDoppler.s.sol). It deploys or reuses the versioned contracts
controlled by [`script/utils/Versions.sol`](../script/utils/Versions.sol), writes deployment outputs back to
[`deployments.config.toml`](../deployments.config.toml) during broadcast runs, and can be rerun after bumping only
the versions that need new deployments.

The intended deployment path is the **Deploy Contracts** GitHub Action. Local commands are supported for
simulation, debugging, and emergency manual execution.

> [!IMPORTANT]
> If deploying locally, please run `forge install`, followed by `forge clean` prior to simulating or broadcasting
> any deployment scripts. This will help ensure installed dependencies are consistent, and aid in contract verification.

> [!IMPORTANT]
> TODO: contract verification is not wired into the deployment workflow yet. Before mainnet deployments, add
> `ETHERSCAN_API_KEY` or the chain-specific verifier secret to the `doppler` repository secrets, pass the relevant
> `--verify` flags to `forge script`, and update the workflow so the Etherscan or verifier endpoint for the target
> chain can be selected. Do not treat a deployment as complete until verification is added or performed manually.

#### Current Wrappers

| Chain        | Chain ID | Protocol script                  | CreateX deployer script                         | Testnet |
| ------------ | -------: | -------------------------------- | ----------------------------------------------- | ------- |
| Ethereum     |      `1` | `DeployDopplerScriptEthereum`    | Create a wrapper before deploying               | `false` |
| Monad        |    `143` | `DeployDopplerScriptMonad`       | Create a wrapper before deploying               | `false` |
| Base         |   `8453` | `DeployDopplerScriptBase`        | Create a wrapper before deploying               | `false` |
| Base Sepolia |  `84532` | `DeployDopplerScriptBaseSepolia` | `DeployDopplerCreateXDeployerScriptBaseSepolia` | `true`  |

Chain-specific wrappers are recommended for both the CreateX deployer script and the protocol deployment script.
They keep the target chain, testnet flag, salts, and expected addresses explicit, and they work cleanly from both
local commands and the GitHub Action.

#### Prepare Config

Before deploying, make sure the target chain is fully represented in the repo:

1. If this is a new supported chain, add its chain ID to
   [`script/utils/ChainIds.sol`](../script/utils/ChainIds.sol).
2. Add or confirm the chain-specific wrapper in `script/DeployDoppler.s.sol`.
3. Add or confirm the chain-specific wrapper in `script/DeployDopplerCreateXDeployer.s.sol`. This wrapper should set
   the mined `salt` and `expectedAddress` for the bootstrap `DopplerCreateXDeployer`.
4. Update [`script/utils/Versions.sol`](../script/utils/Versions.sol) if any deployed protocol contract needs a new
   version.
5. Add the RPC alias to `[rpc_endpoints]` in [`foundry.toml`](../foundry.toml).
6. Add the chain section to [`deployments.config.toml`](../deployments.config.toml).

Each chain section in `deployments.config.toml` needs:

- `[chain] endpoint_url`: the same RPC environment variable used by `foundry.toml`, for example
  `"${BASE_SEPOLIA_RPC_URL}"`.
- `[chain.bool] is_testnet`: `true` only for chains where the script should deploy `AirlockMultisigTestnet`.
- `[chain.address] deployer_owner`: owner for the `DopplerCreateXDeployer`.
- `[chain.address] protocol_deployer`: written after the CreateX deployer broadcast succeeds.
- `[chain.address] airlock_multisig`: required for non-testnets. Testnet deployments write this after deploying
  `AirlockMultisigTestnet`.
- External protocol addresses used by the aggregate deployment: `uniswap_v4_pool_manager`,
  `uniswap_v4_state_view`, `uniswap_v3_factory`, `uniswap_v2_factory`, `weth`, `quoter_v2`, `quoter_v4`, and
  `universal_router`.

Keep the RPC references aligned:

- Local `.env`: `BASE_SEPOLIA_RPC_URL=...`
- `foundry.toml`: `base_sepolia = "${BASE_SEPOLIA_RPC_URL}"`
- `deployments.config.toml`: `[84532] endpoint_url = "${BASE_SEPOLIA_RPC_URL}"`
- GitHub repository secret: `BASE_SEPOLIA_RPC_URL`

#### Deploy DopplerCreateXDeployer

`DopplerCreateXDeployer` must be deployed before the full protocol deployment. The aggregate deployment script
requires `protocol_deployer` in the target chain config and routes deterministic deployments through that contract.

1. Mine a CreateX salt and compute the expected address for `DopplerCreateXDeployer`.

   [`createXcrunch`](https://github.com/HrikB/createXcrunch) is recommended for mining CreateX vanity or
   pattern-matching salts.

2. Set the mined `salt` and `expectedAddress` in the target wrapper in
   `script/DeployDopplerCreateXDeployer.s.sol`.

3. Set `deployer_owner` in the target chain's `deployments.config.toml` section.

4. Simulate the deployment through the GitHub Action or locally.

5. Broadcast the deployment. A successful broadcast writes `protocol_deployer` to `deployments.config.toml`.

Primary GitHub Action simulation input:

```text
script_name: DeployDopplerCreateXDeployerScriptBaseSepolia
broadcast: false
rpc_url: leave blank for chain-specific wrappers, or override if necessary
```

If the simulation passes, broadcast with:

```text
script_name: DeployDopplerCreateXDeployerScriptBaseSepolia
broadcast: true
rpc_url: leave blank for chain-specific wrappers, or override if necessary
```

Local equivalent:

```shell
DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")

forge script script/DeployDopplerCreateXDeployer.s.sol \
  --target-contract DeployDopplerCreateXDeployerScriptBaseSepolia \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --sender "$DEPLOYER_ADDRESS" \
  --broadcast \
  --slow \
  --non-interactive \
  -vvv
```

After a GitHub broadcast, review and merge the generated deployment-record PR before running the full protocol
deployment. That PR is what brings the new `protocol_deployer` value back into the branch.

#### Authorize The GitHub Deployer

Before running any other deploy script, the `deployer_owner` must authorize the GitHub workflow deployer address:

```text
0xcCe8c8461F91dCD4c1f99520b685648DF3462D4C
```

Grant only the Deployer role. This address does not need the Admin role and should not receive it.

```shell
cast send <protocol_deployer> \
  "addDeployers(address[])" \
  "[0xcCe8c8461F91dCD4c1f99520b685648DF3462D4C]" \
  --rpc-url <target-rpc-url-or-alias> \
  --private-key <deployer-owner-or-admin-private-key>
```

#### Deploy The Protocol With GitHub Actions

The GitHub Action is the primary process for protocol deployments.

Required `doppler` repository or environment secrets:

- `DEPLOYER_PRIVATE_KEY`: private key for the workflow deployer. The current expected deployer address is
  `0xcCe8c8461F91dCD4c1f99520b685648DF3462D4C`, and it must be authorized as a Deployer on
  `DopplerCreateXDeployer` before the protocol deployment runs.
- Target chain RPC secret, for example `BASE_SEPOLIA_RPC_URL`.
- Any other RPC secrets referenced by `deployments.config.toml` should also exist in the repository environment so
  config loading is consistent across chains.

Run a simulation first:

```text
script_name: DeployDopplerScriptBaseSepolia
broadcast: false
rpc_url: leave blank for chain-specific wrappers
```

If the simulation passes, run the broadcast:

```text
script_name: DeployDopplerScriptBaseSepolia
broadcast: true
rpc_url: leave blank for chain-specific wrappers
```

During workflow execution:

1. The workflow derives the sender from `DEPLOYER_PRIVATE_KEY`.
2. It builds all scripts with `forge build ./script --via-ir`.
3. It runs `forge script` with `--target-contract`, `--private-key`, `--sender`, `--non-interactive`, and `-vvv`.
4. For broadcasts, it also adds `--broadcast --slow`.
5. After a successful broadcast, it runs `make generate-history`.
6. It uploads deployment artifacts and opens a pull request containing broadcast logs, `deployments.config.toml`,
   `Deployments.md`, `Deployments.json`, and per-chain deployment docs.

Review the generated deployment-record PR, confirm the addresses and transaction hashes, then merge it.

#### Local Protocol Deployment

Local execution is mainly for simulation and debugging. Use the same sender that GitHub will use whenever possible.

Simulation:

```shell
DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")

forge script script/DeployDoppler.s.sol \
  --target-contract DeployDopplerScriptBaseSepolia \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --sender "$DEPLOYER_ADDRESS" \
  --non-interactive \
  -vvv
```

Broadcast:

```shell
DEPLOYER_ADDRESS=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")

forge script script/DeployDoppler.s.sol \
  --target-contract DeployDopplerScriptBaseSepolia \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --sender "$DEPLOYER_ADDRESS" \
  --broadcast \
  --slow \
  --non-interactive \
  -vvv

make generate-history
```

Commit the broadcast logs, `deployments.config.toml`, generated deployment docs, and `Deployments.json` after local
broadcasts.

#### Standalone Scripts

Individual scripts in [`script/deploy`](../script/deploy) can still be run directly when deploying one contract at a
time. Use them only after `protocol_deployer` is configured and the broadcasting address is authorized on
`DopplerCreateXDeployer`.

Standalone deploy scripts expose chain-specific wrappers named like `<DeployScriptName>Ethereum`,
`<DeployScriptName>Monad`, `<DeployScriptName>Base`, and `<DeployScriptName>BaseSepolia` when supported. Scripts that
call `_loadConfigForCurrentChain()` instead of selecting a fork internally should be run with a target `--rpc-url`.
