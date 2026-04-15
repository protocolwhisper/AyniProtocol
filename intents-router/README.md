# Ayni Intents Router

An independent off-chain relay service that monitors `AyniProtocol` borrow intents on the LiteForge chain and publishes them to the [NEAR Intents](https://docs.near-intents.org/) solver network, enabling NEAR-based solvers to discover and fill cross-chain borrow orders.

The service watches for `Open` events emitted by the `AyniProtocol` contract (ERC-7683), translates each `ResolvedCrossChainOrder` into a NEAR Intents quote request, and publishes it to the NEAR Message Bus. Solver responses are collected and stored. Lifecycle events (`ClaimFilled`, `ClaimRepaid`, `ClaimCancelled`, `ClaimLiquidated`) are tracked continuously so the in-memory intent state always reflects on-chain reality.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| [Rust toolchain](https://rustup.rs/) | `rustup` + `cargo`; edition 2021 |
| [Docker](https://docs.docker.com/get-docker/) + [Docker Compose](https://docs.docker.com/compose/) | For containerised deployment |
| Deployed `AyniProtocol` contract address | From `forge script` output |
| LiteForge RPC access | Default: `https://liteforge.rpc.caldera.xyz/http` |
| NEAR Intents API key *(optional)* | From [partners.near-intents.org](https://partners.near-intents.org); avoids the 0.2% unauthenticated fee |

---

## Local Development

```bash
# 1. Enter the service directory
cd intents-router

# 2. Create your environment file
cp .env.example .env

# 3. Edit .env — at minimum set:
#    RPC_URL              = your LiteForge RPC endpoint
#    AYNI_PROTOCOL_ADDRESS = deployed contract address
#    NEAR_INTENTS_API_KEY  = your JWT (optional but recommended)
#    TOKEN_MAP_JSON        = EVM→NEAR token address mapping (optional)

# 4. Build
cargo build

# 5. Run tests
cargo test

# 6. Start the service
cargo run
```

On startup you will see structured JSON logs:

```json
{"level":"INFO","message":"Starting ayni-intents-router","contract":"0x...","chain_id":4441}
{"level":"INFO","message":"EVM poller started","start_block":12345}
{"level":"INFO","message":"connected to NEAR Message Bus WebSocket"}
```

Each new borrow intent logs:

```json
{"level":"INFO","message":"Intent opened","order_id":"0xabc...","block":12350}
{"level":"INFO","message":"publishing intent to NEAR Message Bus","asset_in":"nep141:...","amount":"1000000"}
{"level":"INFO","message":"NEAR solver quote received","order_id":"0xabc...","quote_id":"q-123"}
```

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RPC_URL` | Yes | — | LiteForge JSON-RPC endpoint |
| `AYNI_PROTOCOL_ADDRESS` | Yes | — | Deployed `AyniProtocol` contract address |
| `CHAIN_ID` | No | `4441` | LiteForge chain ID |
| `POLL_INTERVAL_SECS` | No | `5` | Seconds between `eth_getLogs` calls |
| `START_BLOCK` | No | `0` | Block to start scanning from on first run (`0` = latest − 100) |
| `NEAR_INTENTS_API_KEY` | No | — | JWT from partners.near-intents.org |
| `NEAR_INTENTS_RPC` | No | Solver relay URL | NEAR Message Bus JSON-RPC endpoint |
| `NEAR_INTENTS_WS` | No | Solver relay WSS URL | NEAR Message Bus WebSocket endpoint |
| `TOKEN_MAP_JSON` | No | `{}` | JSON map of EVM hex address → NEAR `nep141:` identifier |
| `LOG_LEVEL` | No | `info` | `trace` / `debug` / `info` / `warn` / `error` |
| `PORT` | No | `8080` | Health endpoint port |
| `LAST_BLOCK_FILE` | No | `./last_block.json` | Path for the block cursor persistence file |

---

## Docker Deployment

### 1. Prepare the environment file

```bash
cd intents-router
cp .env.example .env
# fill in RPC_URL and AYNI_PROTOCOL_ADDRESS at minimum
```

### 2. Build and start (from the `intents-router/` directory)

```bash
docker compose up --build -d
```

Or from the repository root:

```bash
docker compose -f intents-router/docker-compose.yml up --build -d
```

### 3. View logs

```bash
docker compose logs -f
```

Or from the repository root:

```bash
docker compose -f intents-router/docker-compose.yml logs -f
```

### 4. Stop the service

```bash
docker compose down
```

### 5. Upgrade to a new version

```bash
docker compose down
docker compose up --build -d
```

The block cursor is stored in a named Docker volume (`intents-router-data`) and survives container restarts and image rebuilds.

### 6. Reset and re-scan

To force a full re-scan from a specific block:

```bash
# Set START_BLOCK in .env, then remove the cursor volume
docker compose down
docker volume rm intents-router_intents-router-data
docker compose up -d
```

To re-scan from genesis (use with caution on long-running chains):

```bash
# In .env: START_BLOCK=0
# Then remove the cursor volume as above
```

---

## Token Mapping

EVM token addresses on LiteForge must be mapped to their NEAR `nep141:` identifiers before the router can publish meaningful quote requests to the NEAR Message Bus.

Set `TOKEN_MAP_JSON` in `.env` as a single-line JSON object:

```bash
TOKEN_MAP_JSON={"<evm_hex_no_0x>":"nep141:<near_contract>","<evm_hex_no_0x>":"nep141:<near_contract>"}
```

Example:

```bash
TOKEN_MAP_JSON={"a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48":"nep141:usdc.near","c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":"nep141:wrap.near"}
```

If a token address has no entry in the map the router falls back to `nep141:<hex_address>`. NEAR solvers can still respond, but may not recognise unlisted tokens.

---

## Architecture

```
LiteForge EVM (Chain 4441)          NEAR Intents Solver Network
       │                                      │
AyniProtocol.Open event                       │
       │                                      │
       ▼                                      │
  evm_poller_task ─── EvmEvent::Open ──► router_task ──► POST /rpc method=quote
  (eth_getLogs poll)                          │
       │  ClaimFilled /              ┌────────┤
       │  Repaid / Cancelled /       │  SharedState
       └─ Liquidated ───────────────►│  (in-memory)
                                     └────────┘
                                          ▲
                               near_ws_task (subscribe "quote" topic)
                               receives solver quote responses
```

Three concurrent `tokio` tasks communicate via `mpsc` channels:

| Task | Description |
|------|-------------|
| `evm_poller_task` | Polls `eth_getLogs` every `POLL_INTERVAL_SECS` for all AyniProtocol events |
| `near_ws_task` | Maintains WebSocket to the NEAR Message Bus; auto-reconnects on disconnect |
| `router_task` | Processes events: updates state, publishes NEAR quote requests, logs lifecycle |

---

## Development Notes

- **No testnet** — The NEAR Intents Message Bus and LiteForge are mainnet-only. Use small amounts when testing end-to-end.
- **Idempotent re-scans** — The router is safe to restart. Duplicate `Open` events for already-tracked intents are silently ignored.
- **Block cursor** — Stored atomically (write-then-rename) after each `eth_getLogs` batch. At most one batch of ≤500 blocks may be re-processed on an unclean shutdown.
