use crate::abi::{ClaimCancelled, ClaimFilled, ClaimLiquidated, ClaimRepaid, Open};
use crate::state::{IntentLifecycle, IntentRecord};
use alloy_primitives::FixedBytes;
use alloy_sol_types::SolEvent;

/// Raw log as returned by eth_getLogs JSON-RPC.
#[derive(Debug, serde::Deserialize)]
pub struct RawLog {
    pub topics: Vec<String>,    // hex strings with 0x prefix
    pub data: String,           // hex with 0x prefix
    #[serde(rename = "blockNumber")]
    pub block_number: Option<String>, // hex
}

impl RawLog {
    pub fn block_number_u64(&self) -> u64 {
        self.block_number
            .as_deref()
            .and_then(|s| u64::from_str_radix(s.trim_start_matches("0x"), 16).ok())
            .unwrap_or(0)
    }

    fn topic0_bytes(&self) -> Option<[u8; 32]> {
        self.topics.first().and_then(|t| decode32(t))
    }
}

/// All data extracted from an `Open` log.
#[derive(Debug, Clone)]
pub struct AyniOpenEvent {
    pub order_id: [u8; 32],
    pub record: IntentRecord,
}

/// Lifecycle state changes after an intent is opened.
#[derive(Debug, Clone)]
pub enum LifecycleEvent {
    Filled {
        order_id: [u8; 32],
        solver: [u8; 20],
    },
    Cancelled {
        order_id: [u8; 32],
    },
    Repaid {
        order_id: [u8; 32],
        repayment_amount: u128,
        protocol_fee: u128,
    },
    Liquidated {
        order_id: [u8; 32],
        claim_proceeds: u128,
        protocol_proceeds: u128,
    },
}

/// Top-level event enum dispatched by the poller.
#[derive(Debug, Clone)]
pub enum EvmEvent {
    Open(AyniOpenEvent),
    Lifecycle(LifecycleEvent),
}

/// Try to decode an `Open` event from a raw log.
/// Returns `None` if the topic0 doesn't match.
pub fn try_decode_open(log: &RawLog) -> anyhow::Result<Option<AyniOpenEvent>> {
    let topic0 = match log.topic0_bytes() {
        Some(t) => t,
        None => return Ok(None),
    };

    let open_hash: [u8; 32] = Open::SIGNATURE_HASH.into();
    if topic0 != open_hash {
        return Ok(None);
    }

    let block_number = log.block_number_u64();

    // Parse topics (indexed params) and data (non-indexed)
    let topics: Vec<FixedBytes<32>> = log
        .topics
        .iter()
        .map(|t| {
            let bytes = decode32(t).unwrap_or([0u8; 32]);
            FixedBytes::from(bytes)
        })
        .collect();

    let data_bytes = hex::decode(log.data.trim_start_matches("0x"))
        .map_err(|e| anyhow::anyhow!("data hex decode: {e}"))?;

    let decoded = Open::decode_raw_log(topics.iter().copied(), &data_bytes, true)
        .map_err(|e| anyhow::anyhow!("Open decode: {e}"))?;

    let order_id: [u8; 32] = decoded.orderId.into();
    let resolved = &decoded.resolvedOrder;

    // Extract collateral token from maxSpent[0].token (bytes32 → address, last 20 bytes)
    let collateral_token = resolved
        .maxSpent
        .first()
        .map(|o| bytes32_to_address(o.token.into()))
        .unwrap_or([0u8; 20]);

    // Extract debt asset, amount, destination from minReceived[0]
    let (debt_asset, requested_amount, destination_chain) =
        resolved.minReceived.first().map(|o| {
            (
                bytes32_to_address(o.token.into()),
                u128::try_from(o.amount).unwrap_or(u128::MAX),
                u64::try_from(o.chainId).unwrap_or(0),
            )
        }).unwrap_or(([0u8; 20], 0, 0));

    let borrower: [u8; 20] = resolved.user.into();

    let record = IntentRecord {
        order_id,
        borrower,
        collateral_token,
        debt_asset,
        requested_amount,
        fill_deadline: resolved.fillDeadline,
        destination_chain,
        near_quote_id: None,
        lifecycle: IntentLifecycle::Open,
        opened_at_block: block_number,
    };

    Ok(Some(AyniOpenEvent { order_id, record }))
}

/// Try to decode a lifecycle event from a raw log.
/// Returns `None` if the topic0 doesn't match any known lifecycle event.
pub fn try_decode_lifecycle(log: &RawLog) -> anyhow::Result<Option<LifecycleEvent>> {
    let topic0 = match log.topic0_bytes() {
        Some(t) => t,
        None => return Ok(None),
    };

    let topics: Vec<FixedBytes<32>> = log
        .topics
        .iter()
        .map(|t| FixedBytes::from(decode32(t).unwrap_or([0u8; 32])))
        .collect();

    let data_bytes = hex::decode(log.data.trim_start_matches("0x"))
        .map_err(|e| anyhow::anyhow!("data hex decode: {e}"))?;

    let filled_hash: [u8; 32] = ClaimFilled::SIGNATURE_HASH.into();
    let cancelled_hash: [u8; 32] = ClaimCancelled::SIGNATURE_HASH.into();
    let repaid_hash: [u8; 32] = ClaimRepaid::SIGNATURE_HASH.into();
    let liquidated_hash: [u8; 32] = ClaimLiquidated::SIGNATURE_HASH.into();

    if topic0 == filled_hash {
        let d = ClaimFilled::decode_raw_log(topics.iter().copied(), &data_bytes, true)
            .map_err(|e| anyhow::anyhow!("ClaimFilled decode: {e}"))?;
        let order_id: [u8; 32] = d.order_id.into();
        let solver: [u8; 20] = d.solver.into();
        return Ok(Some(LifecycleEvent::Filled { order_id, solver }));
    }

    if topic0 == cancelled_hash {
        let d = ClaimCancelled::decode_raw_log(topics.iter().copied(), &data_bytes, true)
            .map_err(|e| anyhow::anyhow!("ClaimCancelled decode: {e}"))?;
        let order_id: [u8; 32] = d.order_id.into();
        return Ok(Some(LifecycleEvent::Cancelled { order_id }));
    }

    if topic0 == repaid_hash {
        let d = ClaimRepaid::decode_raw_log(topics.iter().copied(), &data_bytes, true)
            .map_err(|e| anyhow::anyhow!("ClaimRepaid decode: {e}"))?;
        let order_id: [u8; 32] = d.order_id.into();
        return Ok(Some(LifecycleEvent::Repaid {
            order_id,
            repayment_amount: u128::try_from(d.repayment_amount).unwrap_or(u128::MAX),
            protocol_fee: u128::try_from(d.protocol_fee).unwrap_or(u128::MAX),
        }));
    }

    if topic0 == liquidated_hash {
        let d = ClaimLiquidated::decode_raw_log(topics.iter().copied(), &data_bytes, true)
            .map_err(|e| anyhow::anyhow!("ClaimLiquidated decode: {e}"))?;
        let order_id: [u8; 32] = d.order_id.into();
        return Ok(Some(LifecycleEvent::Liquidated {
            order_id,
            claim_proceeds: u128::try_from(d.claim_proceeds).unwrap_or(u128::MAX),
            protocol_proceeds: u128::try_from(d.protocol_proceeds).unwrap_or(u128::MAX),
        }));
    }

    Ok(None)
}

/// ERC-7683 encodes token addresses as right-aligned bytes32.
/// Extract the last 20 bytes as an Ethereum address.
fn bytes32_to_address(b: [u8; 32]) -> [u8; 20] {
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&b[12..]);
    addr
}

/// Decode a 0x-prefixed 32-byte hex string into [u8; 32].
fn decode32(s: &str) -> Option<[u8; 32]> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(stripped).ok()?;
    if bytes.len() == 32 {
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&bytes);
        Some(arr)
    } else {
        None
    }
}
