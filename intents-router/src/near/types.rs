use serde::{Deserialize, Serialize};

/// Sent as `params` in the `quote` JSON-RPC method to the Message Bus.
#[derive(Debug, Serialize)]
pub struct NearQuoteParams {
    pub defuse_asset_identifier_in: String,
    pub defuse_asset_identifier_out: String,
    pub amount_in: String,
}

/// Generic JSON-RPC request wrapper.
#[derive(Debug, Serialize)]
pub struct JsonRpcRequest<P: Serialize> {
    pub jsonrpc: &'static str,
    pub id: u64,
    pub method: &'static str,
    pub params: P,
}

/// Generic JSON-RPC response wrapper.
#[derive(Debug, Deserialize)]
pub struct JsonRpcResponse<R> {
    pub id: u64,
    pub result: Option<R>,
    pub error: Option<JsonRpcError>,
}

#[derive(Debug, Deserialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
}

/// One solver's quote response from the Message Bus.
#[derive(Debug, Deserialize)]
pub struct NearQuoteResult {
    pub quote_id: String,
    pub defuse_asset_identifier_out: String,
    pub amount_out: String,
    pub expiration_time: Option<String>,
}

/// Generic WebSocket message envelope emitted by the Message Bus.
#[derive(Debug, Deserialize)]
pub struct WsIncoming {
    pub method: String,
    pub params: serde_json::Value,
}

/// A quote request forwarded from the Message Bus to solvers.
#[derive(Debug, Clone, Deserialize)]
pub struct NearQuoteRequest {
    pub quote_id: String,
    pub defuse_asset_identifier_in: String,
    pub defuse_asset_identifier_out: String,
    #[serde(alias = "exact_amount_in")]
    pub amount_in: Option<String>,
    #[serde(alias = "exact_amount_out")]
    pub amount_out: Option<String>,
    pub min_deadline_ms: u64,
}
