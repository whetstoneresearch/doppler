# Legacy Contracts

This directory contains contracts, scripts, tests, and docs that are kept for
historical reference only. Do not use these modules for new integrations.

Historical deployment logs remain in `Deployments.md`, `Deployments.json` and
`deployments/` because they are address records, not active module guidance.

## Legacy Documentation

| Document                                                                           | Notes                                                       |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| [`docs/StreamableFeesLockerV2.md`](docs/StreamableFeesLockerV2.md)                 | Legacy streamable fees locker documentation                 |
| [`docs/UniswapV4MulticurveInitializer.md`](docs/UniswapV4MulticurveInitializer.md) | Legacy Uniswap V4 multicurve pool initializer documentation |

## Legacy Module Families

| Legacy modules                                                                                                                                                                                                                   | Current direction                                                                    |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `UniswapV4MulticurveInitializer`, `UniswapV4MulticurveInitializerHook`, `UniswapV4ScheduledMulticurveInitializer`, `UniswapV4ScheduledMulticurveInitializerHook`, `DecayMulticurveInitializer`, `DecayMulticurveInitializerHook` | Use `DopplerHookInitializer` or `UniswapV4Initializer`, depending on the launch flow |
| `UniswapV3Initializer`                                                                                                                                                                                                           | Use `LockableUniswapV3Initializer` only where V3 support is still required           |
| `UniswapV4MigratorSplit`, `UniswapV4MigratorSplitHook`, `UniswapV4MulticurveMigrator`                                                                                                                                            | Use `DopplerHookMigrator`, `UniswapV2MigratorSplit`, or `NoOpMigrator`               |
| `CloneERC20`, `CloneERC20Factory`, `CloneERC20Votes`, `CloneERC20VotesFactory`, `CloneDERC20VotesV2`, `CloneDERC20VotesV2Factory`, `DERC20`, `DERC2080`, `TokenFactory`, `TokenFactory80`                                        | Use `DopplerERC20V1Factory` or `DN404Factory`                                        |
| `ScheduledLaunchDopplerHook`                                                                                                                                                                                                     | Use the current Doppler Hook interfaces and approved hook implementations            |
| `StreamableFeesLocker`, `StreamableFeesLockerV2`                                                                                                                                                                                | Use `StreamableFeesLockerV3`                                                         |

The shared `Multicurve` library remains in active `src/` code where current
modules still depend on it; the legacy status applies to the legacy
initializer and migrator contracts listed above.
