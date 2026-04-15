use crate::error::RouterError;
use std::collections::HashMap;
use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    // EVM
    pub rpc_url: String,
    pub ayni_protocol_address: String, // hex string, lowercased with 0x prefix
    pub chain_id: u64,
    pub poll_interval_secs: u64,
    pub start_block: u64,

    // NEAR Intents
    pub near_intents_api_key: Option<String>,
    pub near_solver_bus_api_key: Option<String>,
    pub near_intents_rpc: String,
    pub near_intents_ws: String,
    /// EVM hex address (lowercase, no 0x) → NEAR nep141 identifier
    pub token_map: HashMap<String, String>,

    // Service
    pub log_level: String,
    pub port: u16,

    // Persistence
    pub last_block_file: String,
}

impl Config {
    pub fn from_env() -> Result<Self, RouterError> {
        let rpc_url = require("RPC_URL")?;

        // Normalise address: lowercase, ensure 0x prefix
        let raw_addr = require("AYNI_PROTOCOL_ADDRESS")?;
        let ayni_protocol_address = normalise_address(&raw_addr)
            .ok_or_else(|| RouterError::Config("AYNI_PROTOCOL_ADDRESS: invalid hex address".into()))?;

        let chain_id = env_u64("CHAIN_ID", 4441)?;
        let poll_interval_secs = env_u64("POLL_INTERVAL_SECS", 5)?;
        let start_block = env_u64("START_BLOCK", 0)?;

        let near_intents_api_key = env::var("NEAR_INTENTS_API_KEY").ok().filter(|s| !s.is_empty());
        let near_solver_bus_api_key = env::var("NEAR_SOLVER_BUS_API_KEY")
            .ok()
            .filter(|s| !s.is_empty());
        let near_intents_rpc = env::var("NEAR_INTENTS_RPC")
            .unwrap_or_else(|_| "https://solver-relay-v2.chaindefuser.com/rpc".into());
        let near_intents_ws = env::var("NEAR_INTENTS_WS")
            .unwrap_or_else(|_| "wss://solver-relay-v2.chaindefuser.com/ws".into());

        let token_map_json = env::var("TOKEN_MAP_JSON").unwrap_or_else(|_| "{}".into());
        let token_map: HashMap<String, String> = serde_json::from_str(&token_map_json)
            .map_err(|e| RouterError::Config(format!("TOKEN_MAP_JSON: {e}")))?;

        let log_level = env::var("LOG_LEVEL").unwrap_or_else(|_| "info".into());
        let port = env::var("PORT")
            .unwrap_or_else(|_| "8080".into())
            .parse::<u16>()
            .map_err(|e| RouterError::Config(format!("PORT: {e}")))?;

        let last_block_file =
            env::var("LAST_BLOCK_FILE").unwrap_or_else(|_| "./last_block.json".into());

        Ok(Config {
            rpc_url,
            ayni_protocol_address,
            chain_id,
            poll_interval_secs,
            start_block,
            near_intents_api_key,
            near_solver_bus_api_key,
            near_intents_rpc,
            near_intents_ws,
            token_map,
            log_level,
            port,
            last_block_file,
        })
    }
}

fn require(name: &str) -> Result<String, RouterError> {
    env::var(name).map_err(|_| RouterError::Config(format!("{name} is required but not set")))
}

fn env_u64(name: &str, default: u64) -> Result<u64, RouterError> {
    env::var(name)
        .unwrap_or_else(|_| default.to_string())
        .parse::<u64>()
        .map_err(|e| RouterError::Config(format!("{name}: {e}")))
}

/// Normalise an Ethereum address to lowercase `0x`-prefixed form.
fn normalise_address(raw: &str) -> Option<String> {
    let stripped = raw.strip_prefix("0x").unwrap_or(raw);
    if stripped.len() != 40 || !stripped.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!("0x{}", stripped.to_lowercase()))
}
