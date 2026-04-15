// ABI definitions for all AyniProtocol events we monitor.
// The alloy sol! macro generates typed event structs, SIGNATURE constants,
// and SIGNATURE_HASH (topic0 keccak) for each event.
use alloy_sol_types::sol;

sol! {
    struct Output {
        bytes32 token;
        uint256 amount;
        bytes32 recipient;
        uint256 chainId;
    }

    struct FillInstruction {
        uint256 destinationChainId;
        bytes32 destinationSettler;
        bytes originData;
    }

    struct ResolvedCrossChainOrder {
        address user;
        uint256 originChainId;
        uint32  openDeadline;
        uint32  fillDeadline;
        bytes32 orderId;
        Output[] maxSpent;
        Output[] minReceived;
        FillInstruction[] fillInstructions;
    }

    event Open(bytes32 indexed orderId, ResolvedCrossChainOrder resolvedOrder);

    event ClaimFilled(
        bytes32 indexed order_id,
        address indexed solver,
        address indexed borrower
    );

    event ClaimCancelled(
        bytes32 indexed order_id,
        address indexed borrower
    );

    event ClaimRepaid(
        bytes32 indexed order_id,
        address indexed payer,
        uint256 repayment_amount,
        uint256 protocol_fee
    );

    event ClaimLiquidated(
        bytes32 indexed order_id,
        address indexed claim_holder,
        uint256 claim_proceeds,
        uint256 protocol_proceeds
    );
}
