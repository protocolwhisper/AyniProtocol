use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Mirrors AyniProtocol.ClaimStatus with an extra variant for NEAR publishing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IntentLifecycle {
    /// Open event received, not yet published to NEAR
    Open,
    /// Quote request sent to NEAR Message Bus
    PublishedToNear,
    /// ClaimFilled event received from EVM
    Filled,
    /// ClaimRepaid event received
    Repaid,
    /// ClaimLiquidated event received
    Liquidated,
    /// ClaimCancelled event received
    Cancelled,
    /// fillDeadline passed with no ClaimFilled
    Expired,
}

#[derive(Debug, Clone)]
pub struct IntentRecord {
    pub order_id: [u8; 32],
    pub borrower: [u8; 20],
    pub collateral_token: [u8; 20],
    pub debt_asset: [u8; 20],
    pub requested_amount: u128,
    pub fill_deadline: u32,
    pub destination_chain: u64,
    /// Quote ID returned by the NEAR Message Bus on successful publish
    pub near_quote_id: Option<String>,
    pub lifecycle: IntentLifecycle,
    pub opened_at_block: u64,
}

/// Global shared state — handed as a clone to every task.
pub type SharedState = Arc<RwLock<HashMap<[u8; 32], IntentRecord>>>;

pub fn new_shared_state() -> SharedState {
    Arc::new(RwLock::new(HashMap::new()))
}
