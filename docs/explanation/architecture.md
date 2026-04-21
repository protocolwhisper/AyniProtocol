# AyniProtocol Architecture

This document describes the architecture of the current repository, including the on-chain protocol, off-chain services, and cross-chain borrow intent flow.

## Table of Contents

- [Repository layout](#repository-layout)
- [System context](#system-context)
- [On-chain architecture](#on-chain-architecture)
- [Cross-chain borrow flow](#cross-chain-borrow-flow)
- [Intents router runtime model](#intents-router-runtime-model)
- [Build and deployment touchpoints](#build-and-deployment-touchpoints)
- [Design boundaries](#design-boundaries)

## Repository layout

```mermaid
flowchart TB
  subgraph contracts["Solidity / Foundry"]
    src["src/ - core contracts"]
    test["test/ - Foundry tests"]
    script["script/ - deploy scripts"]
    lib["lib/ - forge dependencies"]
  end

  subgraph rust["Rust services and tools"]
    router["intents-router/ - NEAR Intents relay"]
    bot["intents-bot-solver/ - testnet direct solver bot"]
    oracle_tool["oracle/ - oracle operator helper"]
  end

  foundry["foundry.toml"]
  contracts --> foundry
```

## System context

```mermaid
flowchart LR
  borrower["Borrower / LP"]
  solver["Solver wallet"]
  rpc["EVM RPC (LiteForge or compatible)"]
  near["NEAR Intents network"]
  coingecko["CoinGecko API"]

  subgraph evm["EVM contracts"]
    AP["AyniProtocol (origin settler)"]
    ADS["AyniDestinationSettler"]
    VAULTS["AyniVault + AyniLiquidityPool per market"]
    AO["AyniOracle"]
    TOKENS["Collateral and debt ERC20 tokens"]
  end

  borrower --> rpc
  solver --> rpc
  rpc --> AP
  rpc --> ADS
  rpc --> VAULTS
  VAULTS --> AO
  VAULTS --> TOKENS

  router_svc["intents-router (Rust)"] --> rpc
  router_svc --> near
  bot_svc["intents-bot-solver (Rust)"] --> rpc

  oracle_svc["oracle helper (Rust)"] --> coingecko
  oracle_svc -. optional operator update .-> AO
```

## On-chain architecture

```mermaid
flowchart TB
  subgraph settlement["Cross-chain settlement (ERC-7683 interfaces)"]
    AP["AyniProtocol
IOriginSettler, IAyniClaimOrigin, IAyniClaimDebtRouter"]
    ADS["AyniDestinationSettler
IDestinationSettler"]
    ADS -->|"confirm_fill"| AP
  end

  subgraph markets["Markets and liquidity"]
    FACT["AyniVaultFactory"]
    REG["AyniVaultRegistry"]
    VAULT["AyniVault (AyniVaultCore)"]
    POOL["AyniLiquidityPool"]
    ORACLE["AyniOracle"]
  end

  FACT --> REG
  FACT --> VAULT
  AP --> FACT
  AP --> REG
  AP --> POOL
  VAULT --> ORACLE
  AP --> ORACLE

  subgraph assets["Assets"]
    COLL["Collateral ERC20"]
    DEBT["Debt ERC20"]
    WZ["WrappedZkLTC (optional)"]
  end

  VAULT --> COLL
  VAULT --> DEBT
  POOL --> DEBT
  WZ -. optional collateral role .- COLL
```

## Cross-chain borrow flow

```mermaid
sequenceDiagram
  participant B as Borrower
  participant O as AyniProtocol (origin)
  participant R as intents-router (optional)
  participant N as NEAR Intents
  participant S as Solver
  participant D as AyniDestinationSettler
  participant V as Vault / Liquidity pool

  B->>O: open(...) or openFor(...)
  O-->>O: emit Open(orderId, ResolvedCrossChainOrder)
  O->>V: reserve collateral and record claim

  opt Discovery through NEAR Intents
    R->>O: poll Open and lifecycle logs
    R->>N: publish quote request
    N-->>S: quote opportunities
  end

  S->>D: fill(orderId, originData, fillerData)
  D->>D: transfer debt asset to recipient
  D->>O: confirm_fill(orderId, solver, originData)
  O-->>O: claim status transitions to FILLED
  O->>V: finalize borrow accounting
```

## Intents router runtime model

```mermaid
flowchart LR
  evm["evm_poller_task (eth_getLogs)"] -->|EvmEvent| router["router_task"]
  ws["near_ws_task (WebSocket)"] -->|solver quotes| router
  router --> near_http["NEAR HTTP client"]
  router --> state["SharedState (in-memory)"]
  evm --> cursor["last_block.json cursor"]
```

## Build and deployment touchpoints

```mermaid
flowchart LR
  forge["forge build/test"]
  deploy["DeployProtocol.s.sol and DeployOracle.s.sol"]
  cargo["cargo build/test"]

  src["src/"] --> forge
  script["script/"] --> deploy
  router["intents-router/"] --> cargo
  bot["intents-bot-solver/"] --> cargo
  oracle["oracle/"] --> cargo
```

## Design boundaries

- On-chain contracts enforce custody and economic invariants.
- Rust services are operational helpers (relay, bot, operator tooling), not protocol trust anchors.
- Cross-chain intent primitives follow `src/intents/ERC7683.sol`.
- For exact business rules and edge-case behavior, treat `src/` and `test/` as the source of truth.
