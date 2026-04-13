// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAyniFactory} from "./interfaces/IAyniFactory.sol";
import {IAyniClaimOrigin} from "./interfaces/IAyniClaimOrigin.sol";
import {IAyniClaimDebtRouter} from "./interfaces/IAyniClaimDebtRouter.sol";
import {IAyniRegistry} from "./interfaces/IAyniRegistry.sol";
import {IAyniSolverPool} from "./interfaces/IAyniSolverPool.sol";
import {IAyniVaultActions} from "./interfaces/IAyniVaultActions.sol";
import {IAyniVaultView} from "./interfaces/IAyniVaultView.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./utils/SafeERC20.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {
    FillInstruction,
    GaslessCrossChainOrder,
    IOriginSettler,
    OnchainCrossChainOrder,
    Output,
    ResolvedCrossChainOrder
} from "./intents/ERC7683.sol";

contract AyniProtocol is IOriginSettler, IAyniClaimOrigin, IAyniClaimDebtRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant AYNI_ORDER_DATA_TYPE = keccak256(
        "AyniOrderData(address collateral_token,address debt_asset,uint256 requested_amount,bytes32 recipient,uint256 destination_chain_id)"
    );

    enum ClaimStatus {
        NONE,
        OPEN,
        FILLED,
        CANCELLED,
        REPAID,
        LIQUIDATED
    }

    struct MarketSummary {
        address vault;
        address collateral_token;
        address debt_asset;
        address oracle;
        address vault_owner;
        bool active;
        bool paused;
        uint256 total_collateral;
        uint256 total_debt;
        uint256 available_liquidity;
    }

    struct AyniOrderData {
        address collateral_token;
        address debt_asset;
        uint256 requested_amount;
        bytes32 recipient;
        uint256 destination_chain_id;
    }

    struct FillOriginData {
        address recipient;
        address debt_asset;
        uint256 amount;
    }

    struct DebtPosition {
        address vault;
        address borrower;
        address recipient;
        address collateral_token;
        address debt_asset;
        uint256 principal;
        uint256 protocol_fee_bps;
        uint256 fill_deadline;
        uint256 filled_at;
        bytes32 expected_fill_hash;
        ClaimStatus status;
    }

    address private immutable _owner;

    IAyniFactory public immutable factory;
    IAyniRegistry public immutable registry;

    address public destination_settler;

    mapping(bytes32 => address) public claim_holder;

    mapping(bytes32 => DebtPosition) private _debt_positions;
    mapping(address => uint256) private _order_nonce;
    mapping(address => address) private _solver_pools;
    mapping(bytes32 => address) private _claim_pools;

    event MarketCreated(
        address indexed vault, address indexed collateral_token, address debt_asset, address oracle, address vault_owner
    );
    event DestinationSettlerUpdated(address indexed old_settler, address indexed new_settler);
    event SolverPoolUpdated(address indexed vault, address indexed old_pool, address indexed new_pool);
    event ClaimTransferred(bytes32 indexed order_id, address indexed from, address indexed to);
    event ClaimFilled(bytes32 indexed order_id, address indexed solver, address indexed borrower);
    event ClaimCancelled(bytes32 indexed order_id, address indexed borrower);
    event ClaimRepaid(bytes32 indexed order_id, address indexed payer, uint256 repayment_amount, uint256 protocol_fee);
    event ClaimLiquidated(
        bytes32 indexed order_id, address indexed claim_holder, uint256 claim_proceeds, uint256 protocol_proceeds
    );

    modifier onlyOwner() {
        require(msg.sender == _owner, "Protocol: not owner");
        _;
    }

    modifier onlyDestinationSettler() {
        require(msg.sender == destination_settler, "Protocol: not destination settler");
        _;
    }

    constructor(address factory_, address registry_, address owner_) {
        require(factory_ != address(0), "Protocol: bad factory");
        require(registry_ != address(0), "Protocol: bad registry");
        require(owner_ != address(0), "Protocol: bad owner");

        _initializeReentrancyGuard();
        factory = IAyniFactory(factory_);
        registry = IAyniRegistry(registry_);
        _owner = owner_;
    }

    function admin() external view returns (address) {
        return _owner;
    }

    function factory_address() external view returns (address) {
        return address(factory);
    }

    function registry_address() external view returns (address) {
        return address(registry);
    }

    function get_debt_position(bytes32 order_id)
        external
        view
        returns (
            address vault,
            address borrower,
            address recipient,
            address collateral_token,
            address debt_asset,
            uint256 principal,
            uint256 protocol_fee_bps,
            uint256 fill_deadline,
            uint256 filled_at,
            bytes32 expected_fill_hash,
            uint8 status
        )
    {
        DebtPosition storage position = _debt_positions[order_id];

        return (
            position.vault,
            position.borrower,
            position.recipient,
            position.collateral_token,
            position.debt_asset,
            position.principal,
            position.protocol_fee_bps,
            position.fill_deadline,
            position.filled_at,
            position.expected_fill_hash,
            uint8(position.status)
        );
    }

    function order_nonce(address user) external view returns (uint256) {
        return _order_nonce[user];
    }

    function set_destination_settler(address new_settler) external onlyOwner {
        require(new_settler != address(0), "Protocol: bad settler");
        address old_settler = destination_settler;
        destination_settler = new_settler;
        emit DestinationSettlerUpdated(old_settler, new_settler);
    }

    function set_solver_pool(address collateral_token, address debt_asset, address new_pool) external onlyOwner {
        require(new_pool != address(0), "Protocol: bad pool");
        address vault = _requireMarket(collateral_token, debt_asset);
        address old_pool = _solver_pools[vault];
        _solver_pools[vault] = new_pool;
        emit SolverPoolUpdated(vault, old_pool, new_pool);
    }

    function get_solver_pool(address collateral_token, address debt_asset) external view returns (address) {
        return _solver_pools[_requireMarket(collateral_token, debt_asset)];
    }

    function create_market(address collateral_token, address debt_asset, address oracle, address vault_owner)
        external
        onlyOwner
        nonReentrant
        returns (address vault)
    {
        vault = factory.create_vault(collateral_token, debt_asset, oracle, vault_owner);
        emit MarketCreated(vault, collateral_token, debt_asset, oracle, vault_owner);
    }

    function get_market(address collateral_token, address debt_asset) external view returns (address) {
        return registry.get_vault(collateral_token, debt_asset);
    }

    function get_market_summary(address collateral_token, address debt_asset)
        external
        view
        returns (MarketSummary memory)
    {
        address vault = registry.get_vault(collateral_token, debt_asset);
        require(vault != address(0), "Protocol: market missing");

        (uint256 market_id, address collateralAsset, address debtAsset, address oracle, address vaultOwner, bool active) =
            registry.get_vault_metadata(vault);
        require(market_id != 0, "Protocol: bad market");

        IAyniVaultView vaultView = IAyniVaultView(vault);
        return MarketSummary({
            vault: vault,
            collateral_token: collateralAsset,
            debt_asset: debtAsset,
            oracle: oracle,
            vault_owner: vaultOwner,
            active: active,
            paused: vaultView.paused(),
            total_collateral: vaultView.total_collateral(),
            total_debt: vaultView.total_debt(),
            available_liquidity: vaultView.available_liquidity()
        });
    }

    function health_factor(address collateral_token, address debt_asset, address user) external view returns (uint256) {
        return IAyniVaultView(_requireMarket(collateral_token, debt_asset)).health_factor(user);
    }

    function collateral_usd(address collateral_token, address debt_asset, address user)
        external
        view
        returns (uint256)
    {
        return IAyniVaultView(_requireMarket(collateral_token, debt_asset)).collateral_usd(user);
    }

    function max_borrow(address collateral_token, address debt_asset, address user) external view returns (uint256) {
        return IAyniVaultView(_requireMarket(collateral_token, debt_asset)).max_borrow(user);
    }

    function available_liquidity(address collateral_token, address debt_asset) external view returns (uint256) {
        return IAyniVaultView(_requireMarket(collateral_token, debt_asset)).available_liquidity();
    }

    function deposit(address collateral_token, address debt_asset, uint256 amount) external {
        IAyniVaultActions(_requireMarket(collateral_token, debt_asset)).deposit_for(msg.sender, amount);
    }

    function withdraw(address collateral_token, address debt_asset, uint256 amount) external {
        IAyniVaultActions(_requireMarket(collateral_token, debt_asset)).withdraw_for(msg.sender, amount);
    }

    function borrow(address collateral_token, address debt_asset, uint256 amount) external {
        IAyniVaultActions(_requireMarket(collateral_token, debt_asset)).borrow_for(msg.sender, amount);
    }

    function repay(address collateral_token, address debt_asset, uint256 amount) external {
        IAyniVaultActions(_requireMarket(collateral_token, debt_asset)).repay_for(msg.sender, amount);
    }

    function liquidate(address collateral_token, address debt_asset, address user, uint256 debt_to_cover) external {
        IAyniVaultActions(_requireMarket(collateral_token, debt_asset)).liquidate(user, debt_to_cover);
    }

    function cancel_claim(bytes32 order_id) external nonReentrant {
        DebtPosition storage position = _debt_positions[order_id];
        require(position.borrower == msg.sender, "Protocol: not borrower");
        require(position.status == ClaimStatus.OPEN, "Protocol: bad claim");

        position.status = ClaimStatus.CANCELLED;
        IAyniVaultActions(position.vault).cancel_solver_borrow_for(order_id, position.borrower);

        emit ClaimCancelled(order_id, position.borrower);
    }

    function confirm_fill(bytes32 order_id, address solver, bytes calldata origin_data)
        external
        onlyDestinationSettler
        nonReentrant
    {
        require(solver != address(0), "Protocol: bad solver");

        DebtPosition storage position = _debt_positions[order_id];
        require(position.status == ClaimStatus.OPEN, "Protocol: bad claim");
        require(block.timestamp <= position.fill_deadline, "Protocol: fill expired");
        require(keccak256(origin_data) == position.expected_fill_hash, "Protocol: bad fill data");

        claim_holder[order_id] = solver;
        position.filled_at = block.timestamp;
        position.status = ClaimStatus.FILLED;
        IAyniVaultActions(position.vault).mark_solver_borrow_filled(order_id);

        emit ClaimFilled(order_id, solver, position.borrower);
    }

    function transfer_claim(bytes32 order_id, address new_holder) external nonReentrant {
        require(new_holder != address(0), "Protocol: bad holder");
        require(claim_holder[order_id] == msg.sender, "Protocol: not claim holder");
        require(_debt_positions[order_id].status == ClaimStatus.FILLED, "Protocol: bad claim");

        claim_holder[order_id] = new_holder;

        emit ClaimTransferred(order_id, msg.sender, new_holder);
    }

    function fill_with_pool(bytes32 order_id) external nonReentrant {
        DebtPosition storage position = _debt_positions[order_id];
        require(position.status == ClaimStatus.OPEN, "Protocol: bad claim");
        require(block.timestamp <= position.fill_deadline, "Protocol: fill expired");

        address pool = _solver_pools[position.vault];
        require(pool != address(0), "Protocol: solver pool unset");
        require(position.debt_asset == IAyniSolverPool(pool).asset(), "Protocol: bad pool asset");

        claim_holder[order_id] = pool;
        _claim_pools[order_id] = pool;
        position.filled_at = block.timestamp;
        position.status = ClaimStatus.FILLED;

        IAyniSolverPool(pool).fundClaim(order_id, position.principal, position.borrower);
        IERC20(position.debt_asset).safeTransfer(position.recipient, position.principal);
        IAyniVaultActions(position.vault).mark_solver_borrow_filled_with_debt(order_id, position.principal);

        emit ClaimFilled(order_id, pool, position.borrower);
    }

    // slither-disable-next-line reentrancy-no-eth
    function repay_claim(bytes32 order_id, uint256 amount) external nonReentrant {
        DebtPosition storage position = _debt_positions[order_id];
        address recipient = claim_holder[order_id];

        require(position.status == ClaimStatus.FILLED, "Protocol: bad claim");
        require(recipient != address(0), "Protocol: no claim holder");

        if (recipient == _claim_pools[order_id]) {
            (uint256 actual_paid, uint256 remaining_debt_after) =
                IAyniVaultActions(position.vault).repay_claim_for(order_id, position.borrower, amount);

            IERC20(position.debt_asset).safeTransferFrom(msg.sender, recipient, actual_paid);
            IAyniSolverPool(recipient).settleRepayment(order_id, actual_paid);

            if (remaining_debt_after == 0) {
                position.status = ClaimStatus.REPAID;
                delete _claim_pools[order_id];
                delete claim_holder[order_id];
            }

            emit ClaimRepaid(order_id, msg.sender, actual_paid, 0);
            return;
        }

        (uint256 actual, uint256 remaining_debt) =
            IAyniVaultActions(position.vault).repay_claim_for(order_id, position.borrower, amount);
        uint256 protocol_fee = actual * position.protocol_fee_bps / 10_000;
        uint256 claim_proceeds = actual - protocol_fee;

        if (remaining_debt == 0) {
            position.status = ClaimStatus.REPAID;
            delete _claim_pools[order_id];
            delete claim_holder[order_id];
        }

        if (protocol_fee > 0) {
            IERC20(position.debt_asset).safeTransferFrom(msg.sender, _owner, protocol_fee);
        }

        IERC20(position.debt_asset).safeTransferFrom(msg.sender, recipient, claim_proceeds);

        emit ClaimRepaid(order_id, msg.sender, actual, protocol_fee);
    }

    function liquidate_claim(bytes32 order_id) external nonReentrant {
        DebtPosition storage position = _debt_positions[order_id];
        address recipient = claim_holder[order_id];

        require(position.status == ClaimStatus.FILLED, "Protocol: bad claim");
        require(recipient != address(0), "Protocol: no claim holder");

        if (recipient == _claim_pools[order_id]) {
            uint256 debt_to_cover = IAyniSolverPool(recipient).currentDebt(order_id);
            require(debt_to_cover > 0, "Protocol: no debt");

            position.status = ClaimStatus.LIQUIDATED;
            delete _claim_pools[order_id];
            delete claim_holder[order_id];

            IERC20(position.debt_asset).safeTransferFrom(msg.sender, recipient, debt_to_cover);
            (uint256 collateral_amount,) = IAyniVaultActions(position.vault).liquidate_pool_claim_for(order_id, msg.sender);
            IAyniSolverPool(recipient).settleLiquidation(order_id, debt_to_cover);

            emit ClaimLiquidated(order_id, msg.sender, collateral_amount, 0);
            return;
        }

        position.status = ClaimStatus.LIQUIDATED;
        delete _claim_pools[order_id];
        delete claim_holder[order_id];

        (uint256 claim_proceeds, uint256 protocol_proceeds) =
            IAyniVaultActions(position.vault).liquidate_claim_for(order_id, recipient, _owner);

        emit ClaimLiquidated(order_id, recipient, claim_proceeds, protocol_proceeds);
    }

    function openFor(GaslessCrossChainOrder calldata, bytes calldata, bytes calldata) external pure {
        revert("Protocol: gasless unsupported");
    }

    function open(OnchainCrossChainOrder calldata order) external nonReentrant {
        require(destination_settler != address(0), "Protocol: destination settler unset");

        (
            ResolvedCrossChainOrder memory resolved,
            AyniOrderData memory order_data,
            address vault,
            address recipient,
            bytes32 expected_fill_hash,
            uint256 fee_bps
        ) =
            _resolve_order(msg.sender, order, _order_nonce[msg.sender] + 1);

        uint256 debt_amount = order_data.requested_amount + order_data.requested_amount * fee_bps / 10_000;

        _order_nonce[msg.sender] += 1;
        _debt_positions[resolved.orderId] = DebtPosition({
            vault: vault,
            borrower: msg.sender,
            recipient: recipient,
            collateral_token: order_data.collateral_token,
            debt_asset: order_data.debt_asset,
            principal: order_data.requested_amount,
            protocol_fee_bps: fee_bps,
            fill_deadline: order.fillDeadline,
            filled_at: 0,
            expected_fill_hash: expected_fill_hash,
            status: ClaimStatus.OPEN
        });

        IAyniVaultActions(vault).open_solver_borrow_for(
            resolved.orderId, msg.sender, order_data.requested_amount, debt_amount, order.fillDeadline, fee_bps
        );

        emit Open(resolved.orderId, resolved);
    }

    function resolveFor(GaslessCrossChainOrder calldata, bytes calldata)
        external
        pure
        returns (ResolvedCrossChainOrder memory)
    {
        revert("Protocol: gasless unsupported");
    }

    function resolve(OnchainCrossChainOrder calldata order)
        external
        view
        returns (ResolvedCrossChainOrder memory resolved)
    {
        (resolved,,,,,) = _resolve_order(msg.sender, order, _order_nonce[msg.sender] + 1);
    }

    function claim_debt_state(bytes32 order_id) external view returns (uint256 current_debt, bool managed_by_pool) {
        address pool = _claim_pools[order_id];

        if (
            pool == address(0) || claim_holder[order_id] != pool || _debt_positions[order_id].status != ClaimStatus.FILLED
        ) {
            return (0, false);
        }

        return (IAyniSolverPool(pool).currentDebt(order_id), true);
    }

    function _resolve_order(address user, OnchainCrossChainOrder calldata order, uint256 nonce)
        internal
        view
        returns (
            ResolvedCrossChainOrder memory resolved,
            AyniOrderData memory order_data,
            address vault,
            address recipient,
            bytes32 expected_fill_hash,
            uint256 fee_bps
        )
    {
        require(order.orderDataType == AYNI_ORDER_DATA_TYPE, "Protocol: bad order type");

        order_data = abi.decode(order.orderData, (AyniOrderData));
        vault = _requireMarket(order_data.collateral_token, order_data.debt_asset);
        fee_bps = IAyniVaultView(vault).borrow_fee_bps();

        bytes32 order_id = _build_order_id(user, nonce, order);
        recipient = _recipient_address(user, order_data.recipient);

        Output[] memory max_spent = new Output[](1);
        max_spent[0] = Output({
            token: _toBytes32(order_data.debt_asset),
            amount: order_data.requested_amount,
            recipient: _toBytes32(recipient),
            chainId: order_data.destination_chain_id
        });

        Output[] memory min_received = new Output[](0);
        FillInstruction[] memory instructions = new FillInstruction[](1);
        bytes memory fill_origin_data = abi.encode(
            FillOriginData({
                recipient: recipient,
                debt_asset: order_data.debt_asset,
                amount: order_data.requested_amount
            })
        );
        expected_fill_hash = keccak256(fill_origin_data);
        instructions[0] = FillInstruction({
            destinationChainId: order_data.destination_chain_id,
            destinationSettler: _toBytes32(destination_settler),
            originData: fill_origin_data
        });

        resolved = ResolvedCrossChainOrder({
            user: user,
            originChainId: block.chainid,
            openDeadline: uint32(block.timestamp),
            fillDeadline: order.fillDeadline,
            orderId: order_id,
            maxSpent: max_spent,
            minReceived: min_received,
            fillInstructions: instructions
        });
    }

    function _build_order_id(address user, uint256 nonce, OnchainCrossChainOrder calldata order)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(address(this), user, nonce, block.chainid, order.fillDeadline, order.orderDataType, order.orderData));
    }

    function _recipient_address(address user, bytes32 recipient) internal pure returns (address) {
        if (recipient == bytes32(0)) {
            return user;
        }

        return address(uint160(uint256(recipient)));
    }

    function _toBytes32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _requireMarket(address collateral_token, address debt_asset) internal view returns (address vault) {
        vault = registry.get_vault(collateral_token, debt_asset);
        require(vault != address(0), "Protocol: market missing");
    }
}
