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
    MS{Whetstone<br />MultiSig} --> |set modules|A
    Bundler --> |calls|A

    A[Airlock] --> TFM
    A --> GFM
    A --> LMM
    A --> PIM

    subgraph TFM[TokenFactory Modules]
        TF[TokenFactory]
    end

    style TFM fill:#ECD9FA, color:#000

    TF --o DERC20

    subgraph GFM[GovernanceFactory Modules]
        GovernanceFactory
        NoOpGovernanceFactory
    end

    style GFM fill:#ADF0D4, color:#000

    GovernanceFactory --o Governance
    GovernanceFactory -.->TimelockFactory
    TimelockFactory -.-> Timelock

    style Governance fill:green

    subgraph PIM[PoolInitializer Modules]
        UniswapV3Initializer
        UniswapV4Initializer
        UniswapV4MulticurveInitializer
    end

    style PIM fill:#B6ECF7, color:#000

    UniswapV3Initializer --> |initializes pool| UniswapV3
    UniswapV4Initializer --> |initializes pool| UniswapV4
    UniswapV4MulticurveInitializer --> |initializes pool| UniswapV4

    subgraph LMM[LiquidtyMigrator Modules]
        UniswapV2Migrator
        UniswapV4Migrator
        UniswapV4MulticurveMigrator
    end

    style LMM fill:#F6EEB4, color:#000

    UniswapV2Migrator --> |migrates| UniswapV2
    UniswapV4Migrator --> |migrates| UniswapV4
    UniswapV4MulticurveMigrator --> |migrates| UniswapV4

    style UniswapV2 fill:#ff37c7
    style UniswapV3 fill:#ff37c7
    style UniswapV4 fill:#ff37c7
```
