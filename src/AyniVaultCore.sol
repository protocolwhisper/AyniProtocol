// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAyniOracle} from "./interfaces/IAyniOracle.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

abstract contract AyniVaultCore is ReentrancyGuard {
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
        require(!paused, "Vault: paused");
        require(amount >= min_collateral, "below minimum");

        _accrue(msg.sender);

        positions[msg.sender].collateral += amount;
        total_collateral += amount;

        require(IERC20(_collateral_token).transferFrom(msg.sender, address(this), amount), "deposit transfer failed");

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");

        _accrue(msg.sender);

        uint256 new_collateral = positions[msg.sender].collateral - amount;
        require(
            _health_factor_after(new_collateral, positions[msg.sender].debt) >= MIN_HEALTH_FACTOR,
            "would undercollateralize"
        );

        positions[msg.sender].collateral = new_collateral;
        total_collateral -= amount;

        require(IERC20(_collateral_token).transfer(msg.sender, amount), "withdraw transfer failed");

        emit Withdraw(msg.sender, amount);
    }

    function record_borrow(uint256 amount) external nonReentrant {
        _borrow(msg.sender, amount);
    }

    function deposit_for(address user, uint256 amount) external nonReentrant onlyRouter {
        _deposit(user, amount);
    }

    function withdraw_for(address user, uint256 amount) external nonReentrant onlyRouter {
        _withdraw(user, amount);
    }

    function borrow_for(address user, uint256 amount) external nonReentrant onlyRouter {
        _borrow(user, amount);
    }

    function repay_for(address user, uint256 amount) external nonReentrant onlyRouter {
        _repay(user, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        _repay(msg.sender, amount);
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
        SolverBorrowOrder storage order = _solver_orders[order_id];
        require(order.status == SolverBorrowStatus.OPEN, "Vault: bad order");
        require(block.timestamp <= order.expiry, "Vault: order expired");

        address borrower = order.borrower;
        _accrue(borrower);

        require(active_solver_order[borrower] == order_id, "Vault: inactive order");
        require(positions[borrower].debt == 0, "Vault: existing debt");
        require(_health_factor_after(positions[borrower].collateral, order.debt_amount) >= MIN_HEALTH_FACTOR, "would undercollateralize");

        positions[borrower].debt = order.debt_amount;
        total_debt += order.debt_amount;
        order.status = SolverBorrowStatus.FILLED;
        order.filled_at = block.timestamp;

        emit BorrowRecorded(borrower, order.principal, order.debt_amount - order.principal);
        emit SolverBorrowFilled(order_id, borrower, order.filled_at);
    }

    function repay_claim_for(bytes32 order_id, address user, uint256 amount)
        external
        nonReentrant
        onlyRouter
        returns (uint256 actual)
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

        if (positions[user].debt == 0) {
            order.status = SolverBorrowStatus.REPAID;
            active_solver_order[user] = bytes32(0);
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
            require(IERC20(_collateral_token).transfer(treasury_, protocol_proceeds), "protocol collateral transfer failed");
        }

        require(IERC20(_collateral_token).transfer(claim_holder_, claim_proceeds), "claim collateral transfer failed");

        emit Liquidated(borrower, claim_holder_, claim_proceeds, debt_covered);
        emit ClaimAccountingLiquidated(order_id, borrower, claim_proceeds, protocol_proceeds);
    }

    function _deposit(address user, uint256 amount) internal {
        require(!paused, "Vault: paused");
        require(amount >= min_collateral, "below minimum");

        _accrue(user);

        positions[user].collateral += amount;
        total_collateral += amount;

        require(IERC20(_collateral_token).transferFrom(user, address(this), amount), "deposit transfer failed");

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

        require(IERC20(_collateral_token).transfer(user, amount), "withdraw transfer failed");

        emit Withdraw(user, amount);
    }

    function _borrow(address user, uint256 amount) internal {
        require(!paused, "Vault: paused");
        require(amount > 0, "amount=0");
        require(active_solver_order[user] == bytes32(0), "Vault: solver order active");

        _accrue(user);

        uint256 fee = amount * borrow_fee_bps / BPS_DENOMINATOR;
        uint256 new_debt = positions[user].debt + amount + fee;
        uint256 col_usd = _collateral_usd(user);

        require(col_usd > 0, "no collateral");
        require(new_debt * BPS_DENOMINATOR <= col_usd * max_ltv, "exceeds max LTV");
        require(IERC20(_usdc).balanceOf(address(this)) >= amount, "insufficient liquidity");

        positions[user].debt = new_debt;
        total_debt += amount + fee;
        require(IERC20(_usdc).transfer(user, amount), "borrow transfer failed");

        emit BorrowRecorded(user, amount, fee);
    }

    function _repay(address user, uint256 amount) internal {
        require(amount > 0, "amount=0");

        bytes32 order_id = active_solver_order[user];
        if (order_id != bytes32(0) && _solver_orders[order_id].status == SolverBorrowStatus.FILLED) {
            revert("Vault: use claim repay");
        }

        _accrue(user);

        uint256 actual = _min(amount, positions[user].debt);
        require(actual > 0, "no debt");

        positions[user].debt -= actual;
        total_debt -= actual;

        require(IERC20(_usdc).transferFrom(user, address(this), actual), "repay transfer failed");

        emit Repay(user, actual);
    }

    function liquidate(address user, uint256 debt_to_cover) external nonReentrant {
        require(user != msg.sender, "self liquidation");
        require(active_solver_order[user] == bytes32(0), "Vault: claim-backed debt");

        _accrue(user);

        require(_health_factor(user) < MIN_HEALTH_FACTOR, "position healthy");
        require(debt_to_cover > 0, "amount=0");
        require(debt_to_cover <= positions[user].debt, "too much");

        uint256 collateral_seized = _debtToCollateral(debt_to_cover) * (BPS_DENOMINATOR + liq_penalty) / BPS_DENOMINATOR;
        collateral_seized = _min(collateral_seized, positions[user].collateral);

        positions[user].debt -= debt_to_cover;
        positions[user].collateral -= collateral_seized;
        total_debt -= debt_to_cover;
        total_collateral -= collateral_seized;

        require(IERC20(_usdc).transferFrom(msg.sender, address(this), debt_to_cover), "liquidation transfer failed");
        require(IERC20(_collateral_token).transfer(msg.sender, collateral_seized), "collateral transfer failed");

        emit Liquidated(user, msg.sender, collateral_seized, debt_to_cover);
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

        if (max_debt <= positions[user].debt) {
            return 0;
        }

        return max_debt - positions[user].debt;
    }

    function available_liquidity() external view returns (uint256) {
        return IERC20(_usdc).balanceOf(address(this));
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
        require(IERC20(_usdc).transfer(to, amount), "recover transfer failed");
    }

    function _accrue(address user) internal {
        Position storage position = positions[user];
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
        if (positions[user].debt == 0) {
            return type(uint256).max;
        }

        uint256 col_usd = _collateral_usd(user);
        return col_usd * liq_threshold * MIN_HEALTH_FACTOR / positions[user].debt / BPS_DENOMINATOR;
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

    function _debtToCollateral(uint256 debt_amount) internal view returns (uint256) {
        uint256 price = IAyniOracle(_oracle).get_price();
        return debt_amount * _scaleFactor(collateral_decimals) * _scaleFactor(oracle_decimals) / price
            / _scaleFactor(debt_decimals);
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

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
