// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAyniOracle} from "./interfaces/IAyniOracle.sol";
import {IAyniClaimDebtRouter} from "./interfaces/IAyniClaimDebtRouter.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";
import {SafeERC20} from "./utils/SafeERC20.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

abstract contract AyniVaultCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CONFIG_DELAY = 1 days;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant MIN_HEALTH_FACTOR = 10 ** 18;

    bytes32 private constant PARAM_MAX_LTV = keccak256("max_ltv");
    bytes32 private constant PARAM_LIQ_THRESHOLD = keccak256("liq_threshold");
    bytes32 private constant PARAM_LIQ_PENALTY = keccak256("liq_penalty");
    bytes32 private constant PARAM_BORROW_FEE_BPS = keccak256("borrow_fee_bps");
    bytes32 private constant PARAM_ANNUAL_INTEREST_BPS = keccak256("annual_interest_bps");
    bytes32 private constant PARAM_MIN_COLLATERAL = keccak256("min_collateral");

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event BorrowRecorded(address indexed user, uint256 amount, uint256 fee);
    event Repay(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 collateral_seized, uint256 debt_covered);
    event Paused(address by);
    event Unpaused(address by);
    event RiskParameterUpdateScheduled(bytes32 indexed parameter, uint256 new_value, uint256 execute_after);
    event RiskParameterUpdated(bytes32 indexed parameter, uint256 old_value, uint256 new_value);
    event SolverBorrowOpened(
        bytes32 indexed order_id,
        address indexed borrower,
        uint256 principal,
        uint256 debt_amount,
        uint256 protocol_fee_bps,
        uint256 expiry
    );
    event SolverBorrowCancelled(bytes32 indexed order_id, address indexed borrower);
    event SolverBorrowFilled(bytes32 indexed order_id, address indexed borrower, uint256 filled_at);
    event ClaimAccountingRepaid(bytes32 indexed order_id, address indexed borrower, uint256 amount);
    event ClaimAccountingLiquidated(
        bytes32 indexed order_id,
        address indexed borrower,
        uint256 claim_proceeds,
        uint256 protocol_proceeds
    );
    event ClaimCollateralReleased(bytes32 indexed order_id, address indexed borrower, uint256 collateral_amount);

    enum SolverBorrowStatus {
        NONE,
        OPEN,
        FILLED,
        CANCELLED,
        REPAID,
        LIQUIDATED
    }

    struct Position {
        uint256 collateral;
        uint256 debt;
        uint256 last_update;
    }

    struct PendingUintChange {
        uint256 value;
        uint256 execute_after;
    }

    struct SolverBorrowOrder {
        address borrower;
        uint256 principal;
        uint256 debt_amount;
        uint256 protocol_fee_bps;
        uint256 expiry;
        uint256 filled_at;
        SolverBorrowStatus status;
    }

    address private _collateral_token;
    address private _usdc;
    address private _oracle;
    address private _owner;
    address private _router;
    bool private _initialized;

    uint8 public collateral_decimals;
    uint8 public debt_decimals;
    uint8 public oracle_decimals;

    uint256 public max_ltv;
    uint256 public liq_threshold;
    uint256 public liq_penalty;
    uint256 public borrow_fee_bps;
    uint256 public annual_interest_bps;
    uint256 public min_collateral;

    bool public paused;
    uint256 public total_collateral;
    uint256 public total_debt;

    mapping(address => Position) public positions;
    mapping(address => bytes32) public active_solver_order;

    mapping(bytes32 => SolverBorrowOrder) private _solver_orders;

    PendingUintChange private _pending_max_ltv;
    PendingUintChange private _pending_liq_threshold;
    PendingUintChange private _pending_liq_penalty;
    PendingUintChange private _pending_borrow_fee_bps;
    PendingUintChange private _pending_annual_interest_bps;
    PendingUintChange private _pending_min_collateral;

    modifier onlyOwner() {
        require(msg.sender == _owner, "Vault: not owner");
        _;
    }

    modifier initializer() {
        require(!_initialized, "Vault: initialized");
        _initialized = true;
        _;
    }

    modifier onlyRouter() {
        require(msg.sender == _router, "Vault: not router");
        _;
    }

    constructor() {
        _initialized = true;
        _disableReentrancyGuard();
    }

    function initialize(address collateral_token_, address usdc_, address oracle_, address owner_, address router_)
        external
        initializer
    {
        require(collateral_token_ != address(0), "Vault: bad collateral");
        require(usdc_ != address(0), "Vault: bad usdc");
        require(oracle_ != address(0), "Vault: bad oracle");
        require(owner_ != address(0), "Vault: bad owner");
        require(router_ != address(0), "Vault: bad router");

        _initializeReentrancyGuard();

        _collateral_token = collateral_token_;
        _usdc = usdc_;
        _oracle = oracle_;
        _owner = owner_;
        _router = router_;
        collateral_decimals = _readTokenDecimals(collateral_token_);
        debt_decimals = _readTokenDecimals(usdc_);
        oracle_decimals = _readOracleDecimals(oracle_);

        max_ltv = 7000;
        liq_threshold = 8000;
        liq_penalty = 1000;
        borrow_fee_bps = 50;
        annual_interest_bps = 500;
        min_collateral = _defaultMinCollateral(collateral_decimals);
    }

    function deposit(uint256 amount) external nonReentrant {
        _deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(msg.sender, amount);
    }

    function deposit_for(address user, uint256 amount) external nonReentrant onlyRouter {
        _deposit(user, amount);
    }

    function withdraw_for(address user, uint256 amount) external nonReentrant onlyRouter {
        _withdraw(user, amount);
    }

    function open_solver_borrow_for(
        bytes32 order_id,
        address user,
        uint256 principal,
        uint256 debt_amount,
        uint256 expiry,
        uint256 protocol_fee_bps_
    ) external nonReentrant onlyRouter {
        require(!paused, "Vault: paused");
        require(order_id != bytes32(0), "Vault: bad order");
        require(principal > 0, "amount=0");
        require(expiry > block.timestamp, "Vault: bad expiry");
        require(active_solver_order[user] == bytes32(0), "Vault: solver order active");

        _accrue(user);

        require(positions[user].debt == 0, "Vault: existing debt");
        require(_collateral_usd(user) > 0, "no collateral");
        require(_health_factor_after(positions[user].collateral, debt_amount) >= MIN_HEALTH_FACTOR, "exceeds max LTV");

        active_solver_order[user] = order_id;
        _solver_orders[order_id] = SolverBorrowOrder({
            borrower: user,
            principal: principal,
            debt_amount: debt_amount,
            protocol_fee_bps: protocol_fee_bps_,
            expiry: expiry,
            filled_at: 0,
            status: SolverBorrowStatus.OPEN
        });

        emit SolverBorrowOpened(order_id, user, principal, debt_amount, protocol_fee_bps_, expiry);
    }

    function cancel_solver_borrow_for(bytes32 order_id, address user) external nonReentrant onlyRouter {
        SolverBorrowOrder storage order = _solver_orders[order_id];
        require(order.borrower == user, "Vault: bad borrower");
        require(order.status == SolverBorrowStatus.OPEN, "Vault: bad order");

        order.status = SolverBorrowStatus.CANCELLED;
        active_solver_order[user] = bytes32(0);

        emit SolverBorrowCancelled(order_id, user);
    }

    function mark_solver_borrow_filled(bytes32 order_id) external nonReentrant onlyRouter {
        _markSolverBorrowFilled(order_id, _solver_orders[order_id].debt_amount);
    }

    function mark_solver_borrow_filled_with_debt(bytes32 order_id, uint256 debt_amount)
        external
        nonReentrant
        onlyRouter
    {
        _markSolverBorrowFilled(order_id, debt_amount);
    }

    function _markSolverBorrowFilled(bytes32 order_id, uint256 debt_amount) internal {
        SolverBorrowOrder storage order = _solver_orders[order_id];
        require(order.status == SolverBorrowStatus.OPEN, "Vault: bad order");
        require(block.timestamp <= order.expiry, "Vault: order expired");
        require(debt_amount >= order.principal, "Vault: bad debt amount");

        address borrower = order.borrower;
        _accrue(borrower);

        require(active_solver_order[borrower] == order_id, "Vault: inactive order");
        require(positions[borrower].debt == 0, "Vault: existing debt");
        require(_health_factor_after(positions[borrower].collateral, debt_amount) >= MIN_HEALTH_FACTOR, "would undercollateralize");

        positions[borrower].debt = debt_amount;
        total_debt += debt_amount;
        order.status = SolverBorrowStatus.FILLED;
        order.filled_at = block.timestamp;

        emit BorrowRecorded(borrower, order.principal, debt_amount - order.principal);
        emit SolverBorrowFilled(order_id, borrower, order.filled_at);
    }

    function repay_claim_for(bytes32 order_id, address user, uint256 amount)
        external
        nonReentrant
        onlyRouter
        returns (uint256 actual, uint256 remaining_debt)
    {
        require(amount > 0, "amount=0");

        SolverBorrowOrder storage order = _solver_orders[order_id];
        require(order.borrower == user, "Vault: bad borrower");
        require(order.status == SolverBorrowStatus.FILLED, "Vault: bad order");

        _accrue(user);

        actual = _min(amount, positions[user].debt);
        require(actual > 0, "no debt");

        positions[user].debt -= actual;
        total_debt -= actual;
        remaining_debt = positions[user].debt;

        if (remaining_debt == 0) {
            order.status = SolverBorrowStatus.REPAID;
            active_solver_order[user] = bytes32(0);

            uint256 released = positions[user].collateral;
            if (released > 0) {
                positions[user].collateral = 0;
                total_collateral -= released;
                IERC20(_collateral_token).safeTransfer(user, released);
                emit ClaimCollateralReleased(order_id, user, released);
            }
        }

        emit Repay(user, actual);
        emit ClaimAccountingRepaid(order_id, user, actual);
    }

    function liquidate_claim_for(bytes32 order_id, address claim_holder_, address treasury_)
        external
        nonReentrant
        onlyRouter
        returns (uint256 claim_proceeds, uint256 protocol_proceeds)
    {
        require(claim_holder_ != address(0), "Vault: bad claim holder");
        require(treasury_ != address(0), "Vault: bad treasury");

        SolverBorrowOrder storage order = _solver_orders[order_id];
        require(order.status == SolverBorrowStatus.FILLED, "Vault: bad order");

        address borrower = order.borrower;
        _accrue(borrower);

        require(_health_factor(borrower) < MIN_HEALTH_FACTOR, "position healthy");

        uint256 debt_covered = positions[borrower].debt;
        uint256 collateral_amount = positions[borrower].collateral;

        positions[borrower].debt = 0;
        positions[borrower].collateral = 0;
        total_debt -= debt_covered;
        total_collateral -= collateral_amount;
        active_solver_order[borrower] = bytes32(0);
        order.status = SolverBorrowStatus.LIQUIDATED;

        protocol_proceeds = collateral_amount * order.protocol_fee_bps / BPS_DENOMINATOR;
        claim_proceeds = collateral_amount - protocol_proceeds;

        if (protocol_proceeds > 0) {
            IERC20(_collateral_token).safeTransfer(treasury_, protocol_proceeds);
        }

        IERC20(_collateral_token).safeTransfer(claim_holder_, claim_proceeds);

        emit Liquidated(borrower, claim_holder_, claim_proceeds, debt_covered);
        emit ClaimAccountingLiquidated(order_id, borrower, claim_proceeds, protocol_proceeds);
    }

    function liquidate_pool_claim_for(bytes32 order_id, address recipient)
        external
        nonReentrant
        onlyRouter
        returns (uint256 collateral_amount, uint256 debt_covered)
    {
        require(recipient != address(0), "Vault: bad recipient");

        SolverBorrowOrder storage order = _solver_orders[order_id];
        require(order.status == SolverBorrowStatus.FILLED, "Vault: bad order");

        address borrower = order.borrower;
        _accrue(borrower);

        require(_health_factor(borrower) < MIN_HEALTH_FACTOR, "position healthy");

        debt_covered = positions[borrower].debt;
        collateral_amount = positions[borrower].collateral;

        positions[borrower].debt = 0;
        positions[borrower].collateral = 0;
        total_debt -= debt_covered;
        total_collateral -= collateral_amount;
        active_solver_order[borrower] = bytes32(0);
        order.status = SolverBorrowStatus.LIQUIDATED;

        IERC20(_collateral_token).safeTransfer(recipient, collateral_amount);

        emit Liquidated(borrower, recipient, collateral_amount, debt_covered);
        emit ClaimAccountingLiquidated(order_id, borrower, collateral_amount, 0);
    }

    function _deposit(address user, uint256 amount) internal {
        require(!paused, "Vault: paused");
        require(amount >= min_collateral, "below minimum");

        _accrue(user);

        positions[user].collateral += amount;
        total_collateral += amount;

        IERC20(_collateral_token).safeTransferFrom(user, address(this), amount);

        emit Deposit(user, amount);
    }

    function _withdraw(address user, uint256 amount) internal {
        require(amount > 0, "amount=0");
        require(!_has_pending_solver_order(user), "Vault: pending solver borrow");

        _accrue(user);

        uint256 new_collateral = positions[user].collateral - amount;
        require(
            _health_factor_after(new_collateral, positions[user].debt) >= MIN_HEALTH_FACTOR, "would undercollateralize"
        );

        positions[user].collateral = new_collateral;
        total_collateral -= amount;

        IERC20(_collateral_token).safeTransfer(user, amount);

        emit Withdraw(user, amount);
    }

    function collateral_asset() external view returns (address) {
        return _collateral_token;
    }

    function debt_asset() external view returns (address) {
        return _usdc;
    }

    function oracle_address() external view returns (address) {
        return _oracle;
    }

    function vault_owner() external view returns (address) {
        return _owner;
    }

    function protocol_router() external view returns (address) {
        return _router;
    }

    function health_factor(address user) external view returns (uint256) {
        return _health_factor(user);
    }

    function collateral_usd(address user) external view returns (uint256) {
        return _collateral_usd(user);
    }

    function max_borrow(address user) external view returns (uint256) {
        uint256 col_usd = _collateral_usd(user);
        uint256 max_debt = col_usd * max_ltv / BPS_DENOMINATOR;
        uint256 current_debt = _liveDebt(user);

        if (max_debt <= current_debt) {
            return 0;
        }

        return max_debt - current_debt;
    }

    function debt_of(address user) external view returns (uint256) {
        return _liveDebt(user);
    }

    function solver_order(bytes32 order_id)
        external
        view
        returns (
            address borrower,
            uint256 principal,
            uint256 debt_amount,
            uint256 protocol_fee_bps_,
            uint256 expiry,
            uint256 filled_at,
            uint8 status
        )
    {
        SolverBorrowOrder storage order = _solver_orders[order_id];
        return (
            order.borrower,
            order.principal,
            order.debt_amount,
            order.protocol_fee_bps,
            order.expiry,
            order.filled_at,
            uint8(order.status)
        );
    }

    function set_max_ltv(uint256 v) external onlyOwner {
        _scheduleRiskParameter(PARAM_MAX_LTV, _pending_max_ltv, v);
    }

    function apply_max_ltv() external onlyOwner {
        uint256 new_value = _consumeRiskParameter(_pending_max_ltv);
        require(new_value < liq_threshold, "LTV must be < liquidation threshold");

        uint256 old_value = max_ltv;
        max_ltv = new_value;
        emit RiskParameterUpdated(PARAM_MAX_LTV, old_value, new_value);
    }

    function set_liq_threshold(uint256 v) external onlyOwner {
        _scheduleRiskParameter(PARAM_LIQ_THRESHOLD, _pending_liq_threshold, v);
    }

    function apply_liq_threshold() external onlyOwner {
        uint256 new_value = _consumeRiskParameter(_pending_liq_threshold);
        require(new_value > max_ltv, "threshold must exceed LTV");

        uint256 old_value = liq_threshold;
        liq_threshold = new_value;
        emit RiskParameterUpdated(PARAM_LIQ_THRESHOLD, old_value, new_value);
    }

    function set_liq_penalty(uint256 v) external onlyOwner {
        require(v <= 2000, "max 20%");
        _scheduleRiskParameter(PARAM_LIQ_PENALTY, _pending_liq_penalty, v);
    }

    function apply_liq_penalty() external onlyOwner {
        uint256 new_value = _consumeRiskParameter(_pending_liq_penalty);

        uint256 old_value = liq_penalty;
        liq_penalty = new_value;
        emit RiskParameterUpdated(PARAM_LIQ_PENALTY, old_value, new_value);
    }

    function set_borrow_fee(uint256 v) external onlyOwner {
        require(v <= 500, "max 5%");
        _scheduleRiskParameter(PARAM_BORROW_FEE_BPS, _pending_borrow_fee_bps, v);
    }

    function apply_borrow_fee() external onlyOwner {
        uint256 new_value = _consumeRiskParameter(_pending_borrow_fee_bps);

        uint256 old_value = borrow_fee_bps;
        borrow_fee_bps = new_value;
        emit RiskParameterUpdated(PARAM_BORROW_FEE_BPS, old_value, new_value);
    }

    function set_annual_interest_bps(uint256 v) external onlyOwner {
        require(v <= 5000, "max 50%");
        _scheduleRiskParameter(PARAM_ANNUAL_INTEREST_BPS, _pending_annual_interest_bps, v);
    }

    function apply_annual_interest_bps() external onlyOwner {
        uint256 new_value = _consumeRiskParameter(_pending_annual_interest_bps);

        uint256 old_value = annual_interest_bps;
        annual_interest_bps = new_value;
        emit RiskParameterUpdated(PARAM_ANNUAL_INTEREST_BPS, old_value, new_value);
    }

    function set_min_collateral(uint256 v) external onlyOwner {
        require(v > 0, "min=0");
        _scheduleRiskParameter(PARAM_MIN_COLLATERAL, _pending_min_collateral, v);
    }

    function apply_min_collateral() external onlyOwner {
        uint256 new_value = _consumeRiskParameter(_pending_min_collateral);

        uint256 old_value = min_collateral;
        min_collateral = new_value;
        emit RiskParameterUpdated(PARAM_MIN_COLLATERAL, old_value, new_value);
    }

    function pause() external onlyOwner {
        require(!paused, "Vault: paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        require(paused, "Vault: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    function recover_usdc(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Vault: bad to");
        IERC20(_usdc).safeTransfer(to, amount);
    }

    function _accrue(address user) internal {
        Position storage position = positions[user];
        bytes32 order_id = active_solver_order[user];

        if (order_id != bytes32(0) && _solver_orders[order_id].status == SolverBorrowStatus.FILLED) {
            (uint256 synced_debt, bool managed_by_pool) = IAyniClaimDebtRouter(_router).claim_debt_state(order_id);

            if (managed_by_pool) {
                uint256 previous_debt = position.debt;

                if (synced_debt > previous_debt) {
                    total_debt += synced_debt - previous_debt;
                } else if (previous_debt > synced_debt) {
                    total_debt -= previous_debt - synced_debt;
                }

                position.debt = synced_debt;
                position.last_update = block.timestamp;
                return;
            }
        }

        uint256 elapsed = block.timestamp - position.last_update;

        if (elapsed == 0 || position.debt == 0) {
            position.last_update = block.timestamp;
            return;
        }

        uint256 interest = position.debt * annual_interest_bps * elapsed / SECONDS_PER_YEAR / BPS_DENOMINATOR;
        position.debt += interest;
        total_debt += interest;
        position.last_update = block.timestamp;
    }

    function _collateral_usd(address user) internal view returns (uint256) {
        uint256 price = IAyniOracle(_oracle).get_price();
        return _collateralToDebtValue(positions[user].collateral, price);
    }

    function _health_factor(address user) internal view returns (uint256) {
        uint256 debt = _liveDebt(user);

        if (debt == 0) {
            return type(uint256).max;
        }

        uint256 col_usd = _collateral_usd(user);
        return col_usd * liq_threshold * MIN_HEALTH_FACTOR / debt / BPS_DENOMINATOR;
    }

    function _health_factor_after(uint256 new_col, uint256 new_debt) internal view returns (uint256) {
        if (new_debt == 0) {
            return type(uint256).max;
        }

        uint256 col_usd = _collateralToDebtValue(new_col, IAyniOracle(_oracle).get_price());
        return col_usd * liq_threshold * MIN_HEALTH_FACTOR / new_debt / BPS_DENOMINATOR;
    }

    function _collateralToDebtValue(uint256 collateral_amount, uint256 price) internal view returns (uint256) {
        return collateral_amount * price * _scaleFactor(debt_decimals) / _scaleFactor(collateral_decimals)
            / _scaleFactor(oracle_decimals);
    }

    function _scheduleRiskParameter(bytes32 parameter, PendingUintChange storage pending_change, uint256 new_value)
        internal
    {
        uint256 execute_after = block.timestamp + CONFIG_DELAY;
        pending_change.value = new_value;
        pending_change.execute_after = execute_after;

        emit RiskParameterUpdateScheduled(parameter, new_value, execute_after);
    }

    function _consumeRiskParameter(PendingUintChange storage pending_change) internal returns (uint256 value) {
        uint256 execute_after = pending_change.execute_after;
        require(execute_after != 0, "Vault: change not scheduled");
        require(block.timestamp >= execute_after, "Vault: config timelock");

        value = pending_change.value;
        pending_change.value = 0;
        pending_change.execute_after = 0;
    }

    function _readTokenDecimals(address token) internal view returns (uint8 decimals_) {
        decimals_ = IERC20Metadata(token).decimals();
        require(decimals_ <= 18, "Vault: unsupported decimals");
    }

    function _readOracleDecimals(address oracle_) internal view returns (uint8 decimals_) {
        decimals_ = IAyniOracle(oracle_).price_decimals();
        require(decimals_ <= 18, "Vault: unsupported decimals");
    }

    function _scaleFactor(uint8 decimals_) internal pure returns (uint256) {
        return 10 ** uint256(decimals_);
    }

    function _defaultMinCollateral(uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ <= 2) {
            return 1;
        }

        return 10 ** uint256(decimals_ - 2);
    }

    function _has_pending_solver_order(address user) internal view returns (bool) {
        bytes32 order_id = active_solver_order[user];

        if (order_id == bytes32(0)) {
            return false;
        }

        return _solver_orders[order_id].status == SolverBorrowStatus.OPEN;
    }

    function _liveDebt(address user) internal view returns (uint256 debt) {
        debt = positions[user].debt;

        bytes32 order_id = active_solver_order[user];
        if (order_id == bytes32(0) || _solver_orders[order_id].status != SolverBorrowStatus.FILLED) {
            return debt;
        }

        (uint256 synced_debt, bool managed_by_pool) = IAyniClaimDebtRouter(_router).claim_debt_state(order_id);
        if (managed_by_pool) {
            return synced_debt;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
