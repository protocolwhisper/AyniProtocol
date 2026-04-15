use crate::abi::{ClaimCancelled, ClaimFilled, ClaimLiquidated, ClaimRepaid, Open};
use crate::config::Config;
use crate::evm::decoder::{try_decode_lifecycle, try_decode_open, EvmEvent, RawLog};
use crate::persistence;
use alloy_sol_types::SolEvent;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

/// Maximum blocks to fetch per eth_getLogs call.
const BATCH_SIZE: u64 = 500;
/// Default fallback: scan from (latest - N) when no cursor exists.
const FALLBACK_LOOKBACK: u64 = 100;

#[derive(Debug, Serialize, Deserialize)]
struct JsonRpcResponse<T> {
    result: Option<T>,
    error: Option<serde_json::Value>,
}

/// Keccak256 topic string (0x-prefixed) for a SolEvent.
macro_rules! topic {
    ($event:ty) => {{
        let hash: [u8; 32] = <$event>::SIGNATURE_HASH.into();
        format!("0x{}", hex::encode(hash))
    }};
}

pub async fn run_evm_poller(
    config: Arc<Config>,
    tx: mpsc::Sender<EvmEvent>,
    mut cursor: u64,
) -> anyhow::Result<()> {
    let client = Client::builder()
        .timeout(Duration::from_secs(15))
        .build()?;

    // Precompute topic0 filter strings
    let topics = vec![
        topic!(Open),
        topic!(ClaimFilled),
        topic!(ClaimCancelled),
        topic!(ClaimRepaid),
        topic!(ClaimLiquidated),
    ];

    info!(
        rpc_url = %config.rpc_url,
        contract = %config.ayni_protocol_address,
        start_block = cursor,
        "EVM poller started"
    );

    // If no cursor, start from (latest - fallback)
    if cursor == 0 {
        match get_block_number(&client, &config.rpc_url).await {
            Ok(latest) => {
                cursor = latest.saturating_sub(FALLBACK_LOOKBACK);
                info!(cursor, "no cursor found, starting from latest - {FALLBACK_LOOKBACK}");
            }
            Err(e) => {
                warn!(error = %e, "could not fetch latest block for fallback, starting from 0");
            }
        }
    }

    loop {
        let latest = match get_block_number(&client, &config.rpc_url).await {
            Ok(n) => n,
            Err(e) => {
                warn!(error = %e, "get block number failed, retrying");
                tokio::time::sleep(Duration::from_secs(config.poll_interval_secs)).await;
                continue;
            }
        };

        if latest <= cursor {
            tokio::time::sleep(Duration::from_secs(config.poll_interval_secs)).await;
            continue;
        }

        // Process in batches
        while cursor < latest {
            let from = cursor + 1;
            let to = (cursor + BATCH_SIZE).min(latest);

            debug!(from, to, "fetching logs");

            let logs = match get_logs(&client, &config.rpc_url, &config.ayni_protocol_address, from, to, &topics).await {
                Ok(l) => l,
                Err(e) => {
                    warn!(error = %e, from, to, "eth_getLogs failed, retrying batch");
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    continue;
                }
            };

            for log in &logs {
                match try_decode_open(log) {
                    Ok(Some(event)) => {
                        let order_id_hex = hex::encode(event.order_id);
                        info!(order_id = %order_id_hex, block = log.block_number_u64(), "Intent opened");
                        if tx.send(EvmEvent::Open(event)).await.is_err() {
                            return Ok(());
                        }
                        continue;
                    }
                    Ok(None) => {}
                    Err(e) => {
                        error!(error = %e, "failed to decode Open log");
                        continue;
                    }
                }

                match try_decode_lifecycle(log) {
                    Ok(Some(event)) => {
                        if tx.send(EvmEvent::Lifecycle(event)).await.is_err() {
                            return Ok(());
                        }
                    }
                    Ok(None) => {}
                    Err(e) => {
                        error!(error = %e, "failed to decode lifecycle log");
                    }
                }
            }

            cursor = to;
            if let Err(e) = persistence::write_last_block(&config.last_block_file, cursor).await {
                warn!(error = %e, "failed to persist block cursor");
            }
        }

        tokio::time::sleep(Duration::from_secs(config.poll_interval_secs)).await;
    }
}

async fn get_block_number(client: &Client, rpc_url: &str) -> anyhow::Result<u64> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_blockNumber",
        "params": []
    });

    let resp: JsonRpcResponse<String> = client
        .post(rpc_url)
        .json(&body)
        .send()
        .await?
        .json()
        .await?;

    let hex_str = resp.result.ok_or_else(|| anyhow::anyhow!("eth_blockNumber: no result"))?;
    u64::from_str_radix(hex_str.trim_start_matches("0x"), 16)
        .map_err(|e| anyhow::anyhow!("parse block number: {e}"))
}

async fn get_logs(
    client: &Client,
    rpc_url: &str,
    address: &str,
    from: u64,
    to: u64,
    topics: &[String],
) -> anyhow::Result<Vec<RawLog>> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "eth_getLogs",
        "params": [{
            "address": address,
            "fromBlock": format!("0x{from:x}"),
            "toBlock":   format!("0x{to:x}"),
            "topics":    [topics]   // topics[0] OR-filter
        }]
    });

    let resp: JsonRpcResponse<Vec<RawLog>> = client
        .post(rpc_url)
        .json(&body)
        .send()
        .await?
        .json()
        .await?;

    if let Some(err) = resp.error {
        return Err(anyhow::anyhow!("eth_getLogs RPC error: {err}"));
    }

    Ok(resp.result.unwrap_or_default())
}
