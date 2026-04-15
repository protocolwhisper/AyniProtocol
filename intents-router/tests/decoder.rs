/// Integration tests for the EVM log decoder.
///
/// Exercises `try_decode_open` and `try_decode_lifecycle` with hand-crafted
/// `RawLog` fixtures that mirror what `eth_getLogs` would return on-chain.
use ayni_intents_router::abi::{
    ClaimCancelled, ClaimFilled, ClaimLiquidated, ClaimRepaid, Open, Output, ResolvedCrossChainOrder,
};
use ayni_intents_router::evm::decoder::{try_decode_lifecycle, try_decode_open, LifecycleEvent, RawLog};
use alloy_primitives::{Address, FixedBytes, U256};
use alloy_sol_types::{SolEvent, SolType};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn sig<E: SolEvent>() -> String {
    let hash: [u8; 32] = E::SIGNATURE_HASH.into();
    format!("0x{}", hex::encode(hash))
}

fn bytes32_hex(b: [u8; 32]) -> String {
    format!("0x{}", hex::encode(b))
}

/// Left-pad a 20-byte address to a 32-byte hex topic string.
fn addr_topic(addr: [u8; 20]) -> String {
    let mut buf = [0u8; 32];
    buf[12..].copy_from_slice(&addr);
    bytes32_hex(buf)
}

/// Pad a 20-byte address into bytes32 for use in Output.token / maxSpent fields.
fn addr_as_bytes32(addr: [u8; 20]) -> [u8; 32] {
    let mut buf = [0u8; 32];
    buf[12..].copy_from_slice(&addr);
    buf
}

/// ABI-encode two uint256 values (for ClaimRepaid / ClaimLiquidated data fields).
fn encode_two_u256(a: u128, b: u128) -> String {
    let mut buf = [0u8; 64];
    buf[16..32].copy_from_slice(&a.to_be_bytes());
    buf[48..64].copy_from_slice(&b.to_be_bytes());
    format!("0x{}", hex::encode(buf))
}

// ---------------------------------------------------------------------------
// try_decode_open
// ---------------------------------------------------------------------------

#[test]
fn open_returns_none_for_wrong_topic0() {
    let log = RawLog {
        topics: vec![bytes32_hex([0xff; 32])],
        data: "0x".to_string(),
        block_number: Some("0x01".to_string()),
    };
    let result = try_decode_open(&log).unwrap();
    assert!(result.is_none());
}

#[test]
fn open_returns_none_when_no_topics() {
    let log = RawLog {
        topics: vec![],
        data: "0x".to_string(),
        block_number: None,
    };
    let result = try_decode_open(&log).unwrap();
    assert!(result.is_none());
}

/// Full round-trip: build an Open log using alloy ABI encoding, then decode it.
#[test]
fn open_round_trip() {
    let order_id = [0x01u8; 32];
    let borrower = [0x02u8; 20];
    let collateral = [0xaau8; 20];
    let debt = [0xccu8; 20];
    let fill_deadline: u32 = 9_999_999;

    let resolved = ResolvedCrossChainOrder {
        user: Address::from(borrower),
        originChainId: U256::from(4441u64),
        openDeadline: u32::MAX,
        fillDeadline: fill_deadline,
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

    // Encode the non-indexed data as ABI function parameters (head + tail).
    // alloy-sol-types SolType::abi_encode produces the standard ABI encoding
    // that matches what decode_raw_log expects for the event data field.
    let data_bytes = ResolvedCrossChainOrder::abi_encode(&resolved);
    let data_hex = format!("0x{}", hex::encode(&data_bytes));

    let log = RawLog {
        topics: vec![sig::<Open>(), bytes32_hex(order_id)],
        data: data_hex,
        block_number: Some("0x64".to_string()),
    };

    let event = try_decode_open(&log)
        .expect("decode should not error")
        .expect("should decode Open");

    assert_eq!(event.order_id, order_id);
    assert_eq!(event.record.borrower, borrower);
    assert_eq!(event.record.collateral_token, collateral);
    assert_eq!(event.record.debt_asset, debt);
    assert_eq!(event.record.requested_amount, 500_000u128);
    assert_eq!(event.record.fill_deadline, fill_deadline);
    assert_eq!(event.record.destination_chain, 1u64);
    assert_eq!(event.record.opened_at_block, 100);
}

// ---------------------------------------------------------------------------
// ClaimFilled — all params indexed, empty data
// ---------------------------------------------------------------------------

#[test]
fn lifecycle_claim_filled() {
    let order_id = [0x10u8; 32];
    let solver = [0xaau8; 20];
    let borrower = [0xbbu8; 20];

    let log = RawLog {
        topics: vec![
            sig::<ClaimFilled>(),
            bytes32_hex(order_id),
            addr_topic(solver),
            addr_topic(borrower),
        ],
        data: "0x".to_string(),
        block_number: Some("0x0a".to_string()),
    };

    let event = try_decode_lifecycle(&log)
        .expect("decode should not error")
        .expect("should decode ClaimFilled");

    match event {
        LifecycleEvent::Filled { order_id: oid, solver: sol } => {
            assert_eq!(oid, order_id);
            assert_eq!(sol, solver);
        }
        _ => panic!("expected LifecycleEvent::Filled, got {event:?}"),
    }
}

// ---------------------------------------------------------------------------
// ClaimCancelled — all params indexed, empty data
// ---------------------------------------------------------------------------

#[test]
fn lifecycle_claim_cancelled() {
    let order_id = [0x20u8; 32];
    let borrower = [0xbbu8; 20];

    let log = RawLog {
        topics: vec![
            sig::<ClaimCancelled>(),
            bytes32_hex(order_id),
            addr_topic(borrower),
        ],
        data: "0x".to_string(),
        block_number: None,
    };

    let event = try_decode_lifecycle(&log)
        .expect("decode should not error")
        .expect("should decode ClaimCancelled");

    match event {
        LifecycleEvent::Cancelled { order_id: oid } => {
            assert_eq!(oid, order_id);
        }
        _ => panic!("expected LifecycleEvent::Cancelled, got {event:?}"),
    }
}

// ---------------------------------------------------------------------------
// ClaimRepaid — order_id + payer indexed; two uint256 in data
// ---------------------------------------------------------------------------

#[test]
fn lifecycle_claim_repaid() {
    let order_id = [0x30u8; 32];
    let payer = [0xeeu8; 20];
    let repayment: u128 = 1_000_000;
    let fee: u128 = 5_000;

    let log = RawLog {
        topics: vec![
            sig::<ClaimRepaid>(),
            bytes32_hex(order_id),
            addr_topic(payer),
        ],
        data: encode_two_u256(repayment, fee),
        block_number: None,
    };

    let event = try_decode_lifecycle(&log)
        .expect("decode should not error")
        .expect("should decode ClaimRepaid");

    match event {
        LifecycleEvent::Repaid {
            order_id: oid,
            repayment_amount,
            protocol_fee,
        } => {
            assert_eq!(oid, order_id);
            assert_eq!(repayment_amount, repayment);
            assert_eq!(protocol_fee, fee);
        }
        _ => panic!("expected LifecycleEvent::Repaid, got {event:?}"),
    }
}

// ---------------------------------------------------------------------------
// ClaimLiquidated — order_id + claim_holder indexed; two uint256 in data
// ---------------------------------------------------------------------------

#[test]
fn lifecycle_claim_liquidated() {
    let order_id = [0x40u8; 32];
    let holder = [0xffu8; 20];
    let claim_proceeds: u128 = 2_000_000;
    let protocol_proceeds: u128 = 10_000;

    let log = RawLog {
        topics: vec![
            sig::<ClaimLiquidated>(),
            bytes32_hex(order_id),
            addr_topic(holder),
        ],
        data: encode_two_u256(claim_proceeds, protocol_proceeds),
        block_number: None,
    };

    let event = try_decode_lifecycle(&log)
        .expect("decode should not error")
        .expect("should decode ClaimLiquidated");

    match event {
        LifecycleEvent::Liquidated {
            order_id: oid,
            claim_proceeds: cp,
            protocol_proceeds: pp,
        } => {
            assert_eq!(oid, order_id);
            assert_eq!(cp, claim_proceeds);
            assert_eq!(pp, protocol_proceeds);
        }
        _ => panic!("expected LifecycleEvent::Liquidated, got {event:?}"),
    }
}

// ---------------------------------------------------------------------------
// Unknown topic → None
// ---------------------------------------------------------------------------

#[test]
fn lifecycle_unknown_topic_returns_none() {
    let log = RawLog {
        topics: vec![bytes32_hex([0xdeu8; 32])],
        data: "0x".to_string(),
        block_number: None,
    };
    let result = try_decode_lifecycle(&log).unwrap();
    assert!(result.is_none());
}
