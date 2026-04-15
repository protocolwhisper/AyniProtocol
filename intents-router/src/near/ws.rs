use crate::config::Config;
use crate::near::types::{NearQuoteRequest, WsIncoming};
use base64::{Engine as _, engine::general_purpose};
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{Error as WsError, Message},
};
use tracing::{debug, info, warn};

const RECONNECT_DELAY_SECS: u64 = 5;
const FORBIDDEN_RECONNECT_DELAY_SECS: u64 = 60;
const WS_FORBIDDEN_MARKER: &str = "ws_handshake_forbidden";
const WS_INVALID_SOLVER_KEY_MARKER: &str = "ws_invalid_solver_key";

/// Long-running task that maintains a WebSocket connection to the NEAR
/// Intents Message Bus. Forwards incoming solver quote requests to the
/// `tx` channel. Reconnects automatically on disconnection.
pub async fn run_ws_manager(config: Arc<Config>, tx: mpsc::Sender<NearQuoteRequest>) {
    if config.near_solver_bus_api_key.is_none() {
        warn!(
            "NEAR_SOLVER_BUS_API_KEY is not set; skipping NEAR Message Bus WebSocket connection"
        );
        return;
    }

    if let Some(api_key) = &config.near_solver_bus_api_key {
        if let Some(key_type) = jwt_key_type(api_key) {
            if key_type != "solver" {
                warn!(
                    key_type = %key_type,
                    "NEAR_SOLVER_BUS_API_KEY must be a solver JWT; skipping WebSocket manager"
                );
                return;
            }
        }
    }

    loop {
        info!(url = %config.near_intents_ws, "connecting to NEAR Message Bus WebSocket");

        let mut delay_secs = RECONNECT_DELAY_SECS;

        match connect_and_listen(&config, &tx).await {
            Ok(()) => {
                info!("WebSocket connection closed cleanly");
            }
            Err(e) => {
                if e.to_string().contains(WS_FORBIDDEN_MARKER) {
                    delay_secs = FORBIDDEN_RECONNECT_DELAY_SECS;
                    warn!(
                        delay = delay_secs,
                        "WebSocket handshake rejected (403). Check endpoint access and retrying with longer backoff"
                    );
                } else {
                    warn!(error = %e, "WebSocket error");
                }

                if e.to_string().contains(WS_INVALID_SOLVER_KEY_MARKER) {
                    return;
                }
            }
        }

        if tx.is_closed() {
            return; // receiver dropped; shut down
        }

        info!(delay = delay_secs, "reconnecting WebSocket");
        tokio::time::sleep(Duration::from_secs(delay_secs)).await;
    }
}

async fn connect_and_listen(
    config: &Config,
    tx: &mpsc::Sender<NearQuoteRequest>,
) -> anyhow::Result<()> {
    let ws_stream = connect_ws(config).await?;
    let (mut write, mut read) = ws_stream.split();

    // Subscribe to the "quote" topic to receive user swap requests
    let subscribe = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "subscribe",
        "params": ["quote"]
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
                    Ok(msg) => handle_ws_message(msg, tx),
                    Err(e) => debug!(error = %e, raw = %text, "unknown WebSocket message format"),
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

async fn connect_ws(
    config: &Config,
) -> anyhow::Result<
    tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
> {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    let mut request = config.near_intents_ws.as_str().into_client_request()?;

    let has_api_key = config
        .near_solver_bus_api_key
        .as_ref()
        .map(|k| !k.trim().is_empty())
        .unwrap_or(false);

    if let Some(key) = &config.near_solver_bus_api_key {
        request.headers_mut().insert(
            "Authorization",
            format!("Bearer {key}").parse()?,
        );
    }

    match connect_async(request).await {
        Ok((ws_stream, _)) => Ok(ws_stream),
        Err(WsError::Http(response)) if response.status().as_u16() == 403 && has_api_key => {
            let body = response.body().as_deref().unwrap_or_default();
            let body_lower = String::from_utf8_lossy(body).to_ascii_lowercase();
            if body_lower.contains("solver jwt required")
                || body_lower.contains("authentication required")
            {
                return Err(anyhow::anyhow!(WS_INVALID_SOLVER_KEY_MARKER));
            }
            Err(anyhow::anyhow!(WS_FORBIDDEN_MARKER))
        }
        Err(WsError::Http(response)) if response.status().as_u16() == 403 => {
            Err(anyhow::anyhow!(WS_FORBIDDEN_MARKER))
        }
        Err(e) => Err(e.into()),
    }
}

fn handle_ws_message(msg: WsIncoming, tx: &mpsc::Sender<NearQuoteRequest>) {
    if msg.method != "subscribe" {
        // Includes subscription acks like {"result":"<id>"} and non-event traffic.
        debug!(method = %msg.method, "ignoring non-subscription WebSocket message");
        return;
    }

    if let Ok(quote_req) = serde_json::from_value::<NearQuoteRequest>(msg.params.clone()) {
        if tx.try_send(quote_req).is_err() {
            warn!("WebSocket receiver channel full, dropping quote");
        }
        return;
    }

    debug!(params = ?msg.params, "quote status notification received");
}

fn jwt_key_type(token: &str) -> Option<String> {
    let payload_segment = token.split('.').nth(1)?;
    let decoded = general_purpose::URL_SAFE_NO_PAD
        .decode(payload_segment)
        .or_else(|_| general_purpose::URL_SAFE.decode(payload_segment))
        .ok()?;
    let payload: serde_json::Value = serde_json::from_slice(&decoded).ok()?;
    payload
        .get("key_type")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}
