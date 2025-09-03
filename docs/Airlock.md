# Airlock

Airlock is a protocol facilitating the deployment of new tokens using a modular approach.

## Architecture

Different types of modules can be used to cover the several aspects of the token lifecycle:

| Module            | Role                                                    |
| ----------------- | ------------------------------------------------------- |
| TokenFactory      | Deploys the tokens                                      |
| GovernanceFactory | Deploys governance and timelock contracts               |
| PoolInitializer   | Initializes a liquidity pool, for example on Uniswap V3 |
| LiquidityMigrator | Migrates liquidity from one pool to another             |

_Note: a "module" must be whitelisted before it can be used._

```mermaid
---
title: Protocol Architecture
---

flowchart LR
    MS(Whetstone MultiSig) --> |set modules|A
    Bundler --> |calls|A

    A{Airlock} --> TFM
    A --> GFM
    A --> LMM
    A --> PIM

    subgraph TFM[TokenFactory Modules]
        TF[TokenFactory]
    end

    style TFM fill:#ECD9FA, color:#000

    TF --> |Deploys| DERC20

    subgraph GFM[GovernanceFactory Modules]
        GF[GovernanceFactory]
        NOG[NoOpGovernanceFactory]
    end

    style GFM fill:#ADF0D4, color:#000

    GF --> |Deploys| Governance
    GF --> |Calls| TMF[TimelockFactory]
    TMF --> |Deploys| Timelock

    subgraph PIM[PoolInitializer Modules]
        UniV3Init[UniswapV3Initializer]
        UniV4Init[UniswapV4Initializer]
    end

    style PIM fill:#B6ECF7, color:#000

    UniV3Init --> |initializes pool| UniswapV3
    UniV4Init --> |initializes pool| UniswapV4

    subgraph LMM[LiquidtyMigrator Modules]
        UniswapV2Migrator
        UniswapV4Migrator
    end

    style LMM fill:#F6EEB4, color:#000
```
