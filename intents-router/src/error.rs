use thiserror::Error;

/// Operational errors for the router (several variants are reserved for upcoming paths).
#[derive(Debug, Error)]
#[allow(dead_code)]
pub enum RouterError {
    #[error("EVM RPC error: {0}")]
    EvmRpc(String),

    #[error("log decode error: {0}")]
    LogDecode(String),

    #[error("NEAR RPC error: {0}")]
    NearRpc(String),

    #[error("WebSocket error: {0}")]
    WebSocket(String),

    #[error("persistence error: {0}")]
    Persistence(#[from] std::io::Error),

    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("config error: {0}")]
    Config(String),
}
