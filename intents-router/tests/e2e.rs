//! End-to-end tests: mocked EVM JSON-RPC + NEAR Message Bus HTTP, real poller and router.

use ayni_intents_router::abi::{
    ClaimFilled, Open, Output, ResolvedCrossChainOrder,
};
use ayni_intents_router::config::Config;
use ayni_intents_router::evm::run_evm_poller;
use ayni_intents_router::near::NearClient;
use ayni_intents_router::router::run_router;
use ayni_intents_router::state::{IntentLifecycle, new_shared_state};
use alloy_primitives::{Address, FixedBytes, U256};
use alloy_sol_types::{SolEvent, SolType};
use serde_json::json;
use serial_test::serial;
use std::sync::Arc;
use std::time::Duration;
use tempfile::NamedTempFile;
use tokio::sync::mpsc;
use wiremock::matchers::{body_string_contains, method};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn topic0<E: SolEvent>() -> String {
    let hash: [u8; 32] = E::SIGNATURE_HASH.into();
    format!("0x{}", hex::encode(hash))
}

fn bytes32_hex(b: [u8; 32]) -> String {
    format!("0x{}", hex::encode(b))
}

fn addr_topic(addr: [u8; 20]) -> String {
    let mut buf = [0u8; 32];
    buf[12..].copy_from_slice(&addr);
    bytes32_hex(buf)
}

fn addr_as_bytes32(addr: [u8; 20]) -> [u8; 32] {
    let mut buf = [0u8; 32];
    buf[12..].copy_from_slice(&addr);
    buf
}

fn encode_open_log_data(
    order_id: [u8; 32],
    borrower: [u8; 20],
    collateral: [u8; 20],
    debt: [u8; 20],
) -> String {
    let resolved = ResolvedCrossChainOrder {
        user: Address::from(borrower),
        originChainId: U256::from(4441u64),
        openDeadline: u32::MAX,
        fillDeadline: u32::MAX,
        orderId: FixedBytes::from(order_id),
        maxSpent: vec![Output {
            token: FixedBytes::from(addr_as_bytes32(collateral)),
            amount: U256::from(1_000_000u64),
            recipient: FixedBytes::from([0u8; 32]),
            chainId: U256::from(4441u64),
        }],
        minReceived: vec![Output {
            token: FixedBytes::from(addr_as_bytes32(debt)),
            amount: U256::from(500_000u64),
            recipient: FixedBytes::from([0u8; 32]),
            chainId: U256::from(1u64),
        }],
        fillInstructions: vec![],
    };
    let data_bytes = ResolvedCrossChainOrder::abi_encode(&resolved);
    format!("0x{}", hex::encode(&data_bytes))
}

fn open_raw_log(contract: &str, order_id: [u8; 32], data: &str) -> serde_json::Value {
    json!({
        "address": contract,
        "topics": [topic0::<Open>(), bytes32_hex(order_id)],
        "data": data,
        "blockNumber": "0x64"
    })
}

fn claim_filled_raw_log(
    contract: &str,
    order_id: [u8; 32],
    solver: [u8; 20],
    borrower: [u8; 20],
) -> serde_json::Value {
    json!({
        "address": contract,
        "topics": [
            topic0::<ClaimFilled>(),
            bytes32_hex(order_id),
            addr_topic(solver),
            addr_topic(borrower),
        ],
        "data": "0x",
        "blockNumber": "0x64"
    })
}

async fn mount_evm_mocks(evm: &MockServer, logs: serde_json::Value) {
    Mock::given(method("POST"))
        .and(body_string_contains("eth_blockNumber"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "jsonrpc": "2.0",
            "id": 1,
            "result": "0x64"
        })))
        .mount(evm)
        .await;

    Mock::given(method("POST"))
        .and(body_string_contains("eth_getLogs"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "jsonrpc": "2.0",
            "id": 2,
            "result": logs
        })))
        .mount(evm)
        .await;
}

async fn mount_near_quote_mock(near: &MockServer, quote_id: &str) {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "result": [{
            "quote_id": quote_id,
            "defuse_asset_identifier_out": "nep141:usdc.near",
            "amount_out": "9000"
        }]
    });
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .mount(near)
        .await;
}

struct EnvRestore {
    keys: Vec<&'static str>,
    previous: Vec<Option<String>>,
}

impl EnvRestore {
    fn set(vars: &[(&'static str, &str)]) -> Self {
        let mut keys = Vec::new();
        let mut previous = Vec::new();
        for (k, v) in vars {
            previous.push(std::env::var(k).ok());
            std::env::set_var(k, v);
            keys.push(*k);
        }
        Self { keys, previous }
    }
}

impl Drop for EnvRestore {
    fn drop(&mut self) {
        for (k, prev) in self.keys.iter().zip(self.previous.iter()) {
            if let Some(val) = prev {
                std::env::set_var(k, val);
            } else {
                std::env::remove_var(k);
            }
        }
    }
}

#[tokio::test]
#[serial]
async fn e2e_poller_router_open_publishes_near_quote() {
    let evm = MockServer::start().await;
    let near = MockServer::start().await;

    let contract = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let order_id = [0x01u8; 32];
    let borrower = [0x02u8; 20];
    let collateral = [0xaau8; 20];
    let debt = [0xccu8; 20];
    let data_hex = encode_open_log_data(order_id, borrower, collateral, debt);
    let logs = json!([open_raw_log(contract, order_id, &data_hex)]);

    mount_evm_mocks(&evm, logs).await;
    mount_near_quote_mock(&near, "quote-e2e-1").await;

    let cursor_file = NamedTempFile::new().expect("temp cursor file");
    let cursor_path = cursor_file.path().to_string_lossy().to_string();

    let _env = EnvRestore::set(&[
        ("RPC_URL", &evm.uri()),
        ("AYNI_PROTOCOL_ADDRESS", contract),
        ("NEAR_INTENTS_RPC", &near.uri()),
        ("LAST_BLOCK_FILE", &cursor_path),
        ("POLL_INTERVAL_SECS", "30"),
        ("START_BLOCK", "99"),
        ("TOKEN_MAP_JSON", "{}"),
        ("LOG_LEVEL", "warn"),
    ]);

    let config = Arc::new(Config::from_env().expect("config from env"));
    let state = new_shared_state();
    let near_client = Arc::new(NearClient::new(Arc::clone(&config)).expect("near client"));

    let (evm_tx, evm_rx) = mpsc::channel(32);
    let (ws_tx, ws_rx) = mpsc::channel(32);

    let poller = tokio::spawn(run_evm_poller(
        Arc::clone(&config),
        evm_tx,
        99,
    ));
    let router = tokio::spawn(run_router(
        evm_rx,
        ws_rx,
        Arc::clone(&state),
        near_client,
        Arc::clone(&config),
    ));

    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let map = state.read().await;
        if let Some(rec) = map.get(&order_id) {
            if rec.lifecycle == IntentLifecycle::PublishedToNear
                && rec.near_quote_id.as_deref() == Some("quote-e2e-1")
            {
                break;
            }
        }
        drop(map);
        if tokio::time::Instant::now() > deadline {
            panic!("timeout waiting for PublishedToNear + quote id");
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    poller.abort();
    drop(ws_tx);
    let _ = router.await;
    let _ = poller.await;
}

#[tokio::test]
#[serial]
async fn e2e_poller_router_open_then_lifecycle_in_one_batch() {
    let evm = MockServer::start().await;
    let near = MockServer::start().await;

    let contract = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let order_id = [0x03u8; 32];
    let borrower = [0x04u8; 20];
    let solver = [0x05u8; 20];
    let collateral = [0x11u8; 20];
    let debt = [0x22u8; 20];
    let data_hex = encode_open_log_data(order_id, borrower, collateral, debt);

    let logs = json!([
        open_raw_log(contract, order_id, &data_hex),
        claim_filled_raw_log(contract, order_id, solver, borrower),
    ]);

    mount_evm_mocks(&evm, logs).await;
    mount_near_quote_mock(&near, "quote-e2e-2").await;

    let cursor_file = NamedTempFile::new().expect("temp cursor file");
    let cursor_path = cursor_file.path().to_string_lossy().to_string();

    let _env = EnvRestore::set(&[
        ("RPC_URL", &evm.uri()),
        ("AYNI_PROTOCOL_ADDRESS", contract),
        ("NEAR_INTENTS_RPC", &near.uri()),
        ("LAST_BLOCK_FILE", &cursor_path),
        ("POLL_INTERVAL_SECS", "30"),
        ("START_BLOCK", "99"),
        ("TOKEN_MAP_JSON", "{}"),
        ("LOG_LEVEL", "warn"),
    ]);

    let config = Arc::new(Config::from_env().expect("config from env"));
    let state = new_shared_state();
    let near_client = Arc::new(NearClient::new(Arc::clone(&config)).expect("near client"));

    let (evm_tx, evm_rx) = mpsc::channel(32);
    let (ws_tx, ws_rx) = mpsc::channel(32);

    let poller = tokio::spawn(run_evm_poller(
        Arc::clone(&config),
        evm_tx,
        99,
    ));
    let router = tokio::spawn(run_router(
        evm_rx,
        ws_rx,
        Arc::clone(&state),
        near_client,
        Arc::clone(&config),
    ));

    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    loop {
        let map = state.read().await;
        if let Some(rec) = map.get(&order_id) {
            if rec.lifecycle == IntentLifecycle::Filled
                && rec.near_quote_id.as_deref() == Some("quote-e2e-2")
            {
                break;
            }
        }
        drop(map);
        if tokio::time::Instant::now() > deadline {
            panic!("timeout waiting for Filled + quote id");
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    poller.abort();
    drop(ws_tx);
    let _ = router.await;
    let _ = poller.await;
}
