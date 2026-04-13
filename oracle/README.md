# Oracle Helper

Small Rust utility for fetching `litecoin / usd` from CoinGecko and converting it
to the integer format expected by the onchain oracle.

## Setup

Copy `.env.example` to `.env` and fill in any optional values you want.

## Run

```bash
cd oracle
cargo run
```

Generate a fresh owner wallet for the oracle:

```bash
cd oracle
cargo run -- owner
```

Print a deploy command for the standalone oracle deploy script:

```bash
cd oracle
cargo run -- deploy-command
```

## Output

The tool prints:

- the raw LTC/USD price
- the scaled integer value for the oracle
- the last update timestamp from CoinGecko
- optional `cast send` commands if `ORACLE_CONTRACT_ADDRESS`, `RPC_URL`, and `ACCOUNT` are set

The `owner` command writes a local `generated-owner.json` file containing:

- owner address
- private key

That file is gitignored. Treat it like a hot wallet secret.

## Default source

It uses:

```text
https://api.coingecko.com/api/v3/simple/price?ids=litecoin&vs_currencies=usd&include_last_updated_at=true
```

For test use, this is treated as `LTC / USDC` by assuming `USDC ~= USD`.

## Notes

- The oracle contract itself does not need gas.
- The account that deploys it needs gas.
- The owner address only needs gas when you use owner-only functions such as
  `set_fallback_price`, `apply_fallback_price`, `set_use_fallback`, or `apply_use_fallback`.
