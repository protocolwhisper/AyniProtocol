use crate::config::Config;
use crate::near::types::{NearQuoteRequest, WsIncoming};
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{debug, info, warn};

const RECONNECT_DELAY_SECS: u64 = 5;

/// Long-running task that maintains a WebSocket connection to the NEAR
/// Intents Message Bus. Forwards incoming solver quote requests to the
/// `tx` channel. Reconnects automatically on disconnection.
pub async fn run_ws_manager(config: Arc<Config>, tx: mpsc::Sender<NearQuoteRequest>) {
    loop {
        info!(url = %config.near_intents_ws, "connecting to NEAR Message Bus WebSocket");

        match connect_and_listen(&config, &tx).await {
            Ok(()) => {
                info!("WebSocket connection closed cleanly");
            }
            Err(e) => {
                warn!(error = %e, "WebSocket error");
            }
        }

        if tx.is_closed() {
            return; // receiver dropped; shut down
        }

        info!(delay = RECONNECT_DELAY_SECS, "reconnecting WebSocket");
        tokio::time::sleep(Duration::from_secs(RECONNECT_DELAY_SECS)).await;
    }
}

async fn connect_and_listen(
    config: &Config,
    tx: &mpsc::Sender<NearQuoteRequest>,
) -> anyhow::Result<()> {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    let mut request = config.near_intents_ws.as_str().into_client_request()?;

    if let Some(key) = &config.near_intents_api_key {
        request.headers_mut().insert(
            "Authorization",
            format!("Bearer {key}").parse()?,
        );
    }

    let (ws_stream, _) = connect_async(request).await?;
    let (mut write, mut read) = ws_stream.split();

    // Subscribe to the "quote" topic to receive user swap requests
    let subscribe = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "subscribe",
        "params": { "topic": "quote" }
    });
    write
        .send(Message::Text(subscribe.to_string().into()))
        .await?;

    info!("subscribed to NEAR Message Bus quote topic");

    while let Some(msg) = read.next().await {
        match msg? {
            Message::Text(text) => {
                debug!(msg = %text, "WebSocket message received");
                match serde_json::from_str::<WsIncoming>(&text) {
                    Ok(WsIncoming::Quote { params }) => {
                        if tx.try_send(params).is_err() {
                            warn!("WebSocket receiver channel full, dropping quote");
                        }
                    }
                    Ok(WsIncoming::QuoteStatus { params }) => {
                        debug!(?params, "quote status notification received");
                    }
                    Err(e) => {
                        debug!(error = %e, raw = %text, "unknown WebSocket message format");
                    }
                }
            }
            Message::Ping(data) => {
                write.send(Message::Pong(data)).await?;
            }
            Message::Close(_) => {
                info!("WebSocket server closed connection");
                break;
            }
            _ => {}
        }
    }

    Ok(())
}
