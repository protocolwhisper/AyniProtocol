use crate::config::Config;
use crate::near::types::{JsonRpcRequest, JsonRpcResponse, NearQuoteParams, NearQuoteResult};
use anyhow::Context;
use reqwest::Client;
use std::sync::Arc;
use std::time::Duration;
use tracing::{debug, trace, warn};

const QUOTE_TIMEOUT_SECS: u64 = 4; // slightly above the 3s solver window

pub struct NearClient {
    http: Client,
    config: Arc<Config>,
    id: std::sync::atomic::AtomicU64,
}

impl NearClient {
    pub fn new(config: Arc<Config>) -> anyhow::Result<Self> {
        let http = Client::builder()
            .timeout(Duration::from_secs(QUOTE_TIMEOUT_SECS))
            .build()
            .context("build reqwest client")?;
        Ok(Self {
            http,
            config,
            id: std::sync::atomic::AtomicU64::new(1),
        })
    }

    fn next_id(&self) -> u64 {
        self.id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }

    /// Publish a quote request to the NEAR Intents Message Bus.
    /// Returns the quote ID on success, or None if no quotes came back.
    pub async fn publish_quote_request(
        &self,
        params: NearQuoteParams,
    ) -> anyhow::Result<Option<String>> {
        let request = JsonRpcRequest {
            jsonrpc: "2.0",
            id: self.next_id(),
            method: "quote",
            params,
        };

        debug!(
            asset_in  = %request.params.defuse_asset_identifier_in,
            asset_out = %request.params.defuse_asset_identifier_out,
            amount    = %request.params.amount_in,
            "publishing quote request to NEAR Message Bus"
        );

        let mut req = self.http.post(&self.config.near_intents_rpc).json(&request);

        if let Some(key) = &self.config.near_intents_api_key {
            req = req.header("Authorization", format!("Bearer {key}"));
        }

        let response = req.send().await.context("POST to NEAR Message Bus")?;

        if !response.status().is_success() {
            warn!(status = %response.status(), "NEAR Message Bus returned non-2xx");
            return Ok(None);
        }

        let body: JsonRpcResponse<Vec<NearQuoteResult>> =
            response.json().await.context("parse NEAR quote response")?;

        trace!(rpc_response_id = body.id, "NEAR quote JSON-RPC response");

        if let Some(err) = body.error {
            warn!(code = err.code, message = %err.message, "NEAR RPC error");
            return Ok(None);
        }

        let quotes = body.result.unwrap_or_default();
        if quotes.is_empty() {
            debug!("no solver quotes received (within 3s window)");
            return Ok(None);
        }

        // Select best quote: highest amount_out
        let best = quotes
            .iter()
            .max_by_key(|q| q.amount_out.parse::<u128>().unwrap_or(0));

        if let Some(q) = best {
            debug!(
                quote_id  = %q.quote_id,
                amount_out = %q.amount_out,
                asset_out = %q.defuse_asset_identifier_out,
                expiration_time = ?q.expiration_time,
                "best solver quote selected"
            );
            return Ok(Some(q.quote_id.clone()));
        }

        Ok(None)
    }
}
