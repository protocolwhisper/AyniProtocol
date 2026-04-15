mod abi;
mod config;
mod error;
mod evm;
mod near;
mod persistence;
mod router;
mod state;

use crate::config::Config;
use crate::evm::decoder::EvmEvent;
use crate::near::types::NearQuoteRequest;
use std::sync::Arc;
use tracing::info;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Load .env file if present (same pattern as oracle service)
    let _ = dotenvy::dotenv();

    let config = Arc::new(Config::from_env()?);

    // Initialise structured logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| config.log_level.parse().unwrap_or_default()),
        )
        .json()
        .init();

    info!(
        version = env!("CARGO_PKG_VERSION"),
        contract = %config.ayni_protocol_address,
        chain_id = config.chain_id,
        poll_interval_secs = config.poll_interval_secs,
        port = config.port,
        "Starting ayni-intents-router"
    );

    // Determine the starting block
    let persisted = persistence::read_last_block(&config.last_block_file).await;
    let start_block = if persisted > 0 {
        info!(block = persisted, "resuming from persisted cursor");
        persisted
    } else if config.start_block > 0 {
        info!(block = config.start_block, "using configured START_BLOCK");
        config.start_block
    } else {
        // Default: start from (latest - 100) to catch recent intents without
        // scanning from genesis on a fresh deploy.
        0 // poller will fetch latest and subtract 100 on first run
    };

    // Shared state
    let shared_state = state::new_shared_state();

    // Inter-task channels
    let (evm_tx, evm_rx) = tokio::sync::mpsc::channel::<EvmEvent>(256);
    let (ws_tx, ws_rx) = tokio::sync::mpsc::channel::<NearQuoteRequest>(256);

    // NEAR HTTP client (shared across router task calls)
    let near_client = Arc::new(near::NearClient::new(Arc::clone(&config))?);

    let mut tasks = tokio::task::JoinSet::new();

    // Task 1: Poll LiteForge for AyniProtocol events
    tasks.spawn(evm::run_evm_poller(
        Arc::clone(&config),
        evm_tx,
        start_block,
    ));

    // Task 2: Maintain WebSocket to NEAR Message Bus
    let config_ws = Arc::clone(&config);
    tasks.spawn(async move {
        near::run_ws_manager(config_ws, ws_tx).await;
        Ok(())
    });

    // Task 3: Route events to NEAR and update shared state
    tasks.spawn(router::run_router(
        evm_rx,
        ws_rx,
        Arc::clone(&shared_state),
        Arc::clone(&near_client),
        Arc::clone(&config),
    ));

    // Wait for any task to exit; propagate errors
    while let Some(result) = tasks.join_next().await {
        result??;
    }

    Ok(())
}
