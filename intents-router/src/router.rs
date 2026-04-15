use crate::config::Config;
use crate::evm::decoder::{AyniOpenEvent, EvmEvent, LifecycleEvent};
use crate::near::types::{NearQuoteParams, NearQuoteRequest};
use crate::near::NearClient;
use crate::state::{IntentLifecycle, SharedState};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use tracing::{info, warn};

/// Main router task: receives EVM events and NEAR WebSocket messages,
/// updates shared state, and publishes quote requests to the NEAR Message Bus.
pub async fn run_router(
    mut evm_rx: mpsc::Receiver<EvmEvent>,
    mut ws_rx: mpsc::Receiver<NearQuoteRequest>,
    state: SharedState,
    near_client: Arc<NearClient>,
    config: Arc<Config>,
) -> anyhow::Result<()> {
    loop {
        tokio::select! {
            Some(event) = evm_rx.recv() => {
                match event {
                    EvmEvent::Open(open_event) => {
                        handle_open(open_event, &state, &near_client, &config).await;
                    }
                    EvmEvent::Lifecycle(lc) => {
                        handle_lifecycle(lc, &state).await;
                    }
                }
            }

            Some(quote_req) = ws_rx.recv() => {
                // A solver is asking us for a quote on the Message Bus.
                // For now we log it — a future enhancement would let the router
                // act as a market maker and respond with a signed intent.
                info!(
                    quote_id = %quote_req.quote_id,
                    asset_in = %quote_req.defuse_asset_identifier_in,
                    asset_out = %quote_req.defuse_asset_identifier_out,
                    amount_in = ?quote_req.amount_in,
                    amount_out = ?quote_req.amount_out,
                    min_deadline_ms = quote_req.min_deadline_ms,
                    "solver quote request received (not responding)"
                );
            }

            else => break,
        }
    }

    Ok(())
}

async fn handle_open(
    event: AyniOpenEvent,
    state: &SharedState,
    near_client: &NearClient,
    config: &Config,
) {
    let order_id_hex = hex::encode(event.order_id);

    // Skip if already tracked (idempotent on re-scan)
    {
        let map = state.read().await;
        if map.contains_key(&event.order_id) {
            return;
        }
    }

    // Insert with Open lifecycle
    {
        let mut map = state.write().await;
        map.insert(event.order_id, event.record.clone());
    }

    // Check if the intent has already expired
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as u32;

    if event.record.fill_deadline > 0 && now > event.record.fill_deadline {
        info!(order_id = %order_id_hex, "intent already expired, skipping NEAR publish");
        let mut map = state.write().await;
        if let Some(r) = map.get_mut(&event.order_id) {
            r.lifecycle = IntentLifecycle::Expired;
        }
        return;
    }

    // Translate to NEAR quote params and publish
    let params = translate_to_near_quote(&event, &config.token_map);

    info!(
        order_id  = %order_id_hex,
        record_order_id = %hex::encode(event.record.order_id),
        borrower  = %hex::encode(event.record.borrower),
        destination_chain = event.record.destination_chain,
        opened_at_block = event.record.opened_at_block,
        asset_in  = %params.defuse_asset_identifier_in,
        asset_out = %params.defuse_asset_identifier_out,
        amount    = %params.amount_in,
        "publishing intent to NEAR Message Bus"
    );

    match near_client.publish_quote_request(params).await {
        Ok(Some(quote_id)) => {
            info!(order_id = %order_id_hex, quote_id = %quote_id, "NEAR solver quote received");
            let mut map = state.write().await;
            if let Some(r) = map.get_mut(&event.order_id) {
                r.lifecycle = IntentLifecycle::PublishedToNear;
                r.near_quote_id = Some(quote_id);
            }
        }
        Ok(None) => {
            warn!(order_id = %order_id_hex, "no solver quotes within 3s window");
            let mut map = state.write().await;
            if let Some(r) = map.get_mut(&event.order_id) {
                r.lifecycle = IntentLifecycle::PublishedToNear;
            }
        }
        Err(e) => {
            warn!(order_id = %order_id_hex, error = %e, "failed to publish to NEAR");
        }
    }
}

async fn handle_lifecycle(event: LifecycleEvent, state: &SharedState) {
    match &event {
        LifecycleEvent::Filled { order_id, solver } => {
            let order_id_hex = hex::encode(order_id);
            let solver_hex = hex::encode(solver);
            info!(order_id = %order_id_hex, solver = %solver_hex, "intent FILLED");
            let mut map = state.write().await;
            if let Some(r) = map.get_mut(order_id) {
                r.lifecycle = IntentLifecycle::Filled;
            }
        }
        LifecycleEvent::Cancelled { order_id } => {
            info!(order_id = %hex::encode(order_id), "intent CANCELLED");
            let mut map = state.write().await;
            if let Some(r) = map.get_mut(order_id) {
                r.lifecycle = IntentLifecycle::Cancelled;
            }
        }
        LifecycleEvent::Repaid {
            order_id,
            repayment_amount,
            protocol_fee,
        } => {
            info!(
                order_id = %hex::encode(order_id),
                amount   = repayment_amount,
                protocol_fee = protocol_fee,
                "intent REPAID"
            );
            let mut map = state.write().await;
            if let Some(r) = map.get_mut(order_id) {
                r.lifecycle = IntentLifecycle::Repaid;
            }
        }
        LifecycleEvent::Liquidated {
            order_id,
            claim_proceeds,
            protocol_proceeds,
        } => {
            info!(
                order_id = %hex::encode(order_id),
                proceeds = claim_proceeds,
                protocol_proceeds = protocol_proceeds,
                "intent LIQUIDATED"
            );
            let mut map = state.write().await;
            if let Some(r) = map.get_mut(order_id) {
                r.lifecycle = IntentLifecycle::Liquidated;
            }
        }
    }
}

/// Translate an Ayni Open event into NEAR Intents quote params.
/// Uses TOKEN_MAP_JSON to look up NEAR nep141 identifiers for EVM addresses.
/// Falls back to `nep141:<hex_address>` if no mapping is found.
fn translate_to_near_quote(
    event: &AyniOpenEvent,
    token_map: &std::collections::HashMap<String, String>,
) -> NearQuoteParams {
    let collateral_hex = hex::encode(event.record.collateral_token);
    let debt_hex = hex::encode(event.record.debt_asset);

    let collateral_id = token_map
        .get(&collateral_hex)
        .cloned()
        .unwrap_or_else(|| format!("nep141:{collateral_hex}"));

    let debt_id = token_map
        .get(&debt_hex)
        .cloned()
        .unwrap_or_else(|| format!("nep141:{debt_hex}"));

    NearQuoteParams {
        defuse_asset_identifier_in: collateral_id,
        defuse_asset_identifier_out: debt_id,
        amount_in: event.record.requested_amount.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{IntentLifecycle, IntentRecord};
    use std::collections::HashMap;

    fn make_event(collateral: [u8; 20], debt: [u8; 20], amount: u128) -> AyniOpenEvent {
        AyniOpenEvent {
            order_id: [1u8; 32],
            record: IntentRecord {
                order_id: [1u8; 32],
                borrower: [2u8; 20],
                collateral_token: collateral,
                debt_asset: debt,
                requested_amount: amount,
                fill_deadline: u32::MAX,
                destination_chain: 1,
                near_quote_id: None,
                lifecycle: IntentLifecycle::Open,
                opened_at_block: 100,
            },
        }
    }

    #[test]
    fn translate_uses_token_map() {
        let mut map = HashMap::new();
        let collateral = [0xaa; 20];
        let debt = [0xbb; 20];
        let collateral_hex = hex::encode(collateral);
        let debt_hex = hex::encode(debt);
        map.insert(collateral_hex, "nep141:wzkltc.near".to_string());
        map.insert(debt_hex, "nep141:usdc.near".to_string());

        let event = make_event(collateral, debt, 1_000_000);
        let params = translate_to_near_quote(&event, &map);

        assert_eq!(params.defuse_asset_identifier_in, "nep141:wzkltc.near");
        assert_eq!(params.defuse_asset_identifier_out, "nep141:usdc.near");
        assert_eq!(params.amount_in, "1000000");
    }

    #[test]
    fn translate_falls_back_to_hex() {
        let collateral = [0xcc; 20];
        let debt = [0xdd; 20];
        let event = make_event(collateral, debt, 500);
        let params = translate_to_near_quote(&event, &HashMap::new());

        assert!(params.defuse_asset_identifier_in.starts_with("nep141:"));
        assert!(params.defuse_asset_identifier_out.starts_with("nep141:"));
    }
}
