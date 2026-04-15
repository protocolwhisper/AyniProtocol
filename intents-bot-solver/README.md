# Ayni Intents Bot Solver (Testnet)

`intents-bot-solver` is a direct on-chain solver bot for testnets.  
It monitors `AyniProtocol` events, discovers open debt claims, and calls `AyniDestinationSettler.fill(...)` using USDC from a configured solver wallet.

## What it does

- polls logs from `AyniProtocol`
- extracts candidate order IDs from events
- reads claim state via `get_debt_position(order_id)`
- fills only claims that are:
  - `OPEN`
  - not expired
  - denominated in configured `USDC_TOKEN_ADDRESS`
- auto-approves USDC allowance to the destination settler when needed
- sends `fill(orderId, originData, fillerData)` transactions from solver wallet
- persists last scanned block to resume safely after restart

## Setup

```bash
cd intents-bot-solver
cp .env.example .env
```

Configure at least:

- `RPC_URL`
- `CHAIN_ID`
- `AYNI_PROTOCOL_ADDRESS`
- `DESTINATION_SETTLER_ADDRESS`
- `SOLVER_PRIVATE_KEY`
- `USDC_TOKEN_ADDRESS`

## Run

```bash
cargo run
```

## Notes

- This bot is for **testnet use**.
- Solver wallet must hold:
  - native gas token for tx fees
  - enough USDC for fills
- The bot only fills USDC-denominated claims by design.
