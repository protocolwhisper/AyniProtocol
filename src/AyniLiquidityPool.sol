// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAyniLiquidityPool} from "./interfaces/IAyniLiquidityPool.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC20Metadata} from "./interfaces/IERC20Metadata.sol";
import {Math} from "./utils/Math.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {SafeERC20} from "./utils/SafeERC20.sol";

contract AyniLiquidityPool is IAyniLiquidityPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 public constant CONFIG_DELAY = 1 days;

    uint256 public constant COOLDOWN_PERIOD = 7 days;
    uint256 public constant WITHDRAW_WINDOW = 2 days;

    string public name;
    string public symbol;

    struct LoanRecord {
        uint256 scaledPrincipal;
        uint256 rawPrincipal;
        address borrower;
        bool active;
    }

    struct CooldownState {
        uint40 timestamp;
        uint216 shares;
    }

    struct RateModelConfig {
        uint256 optimalUtilization;
        uint256 baseRate;
        uint256 slope1;
        uint256 slope2;
        uint256 reserveFactor;
    }

    struct PendingRateModelConfig {
        uint256 optimalUtilization;
        uint256 baseRate;
        uint256 slope1;
        uint256 slope2;
        uint256 reserveFactor;
        uint256 executeAfter;
    }

    IERC20 private immutable _asset;
    uint8 public immutable decimals;

    address public protocol;
    address public owner;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public liquidityIndex;
    uint256 public currentBorrowRate;
    uint256 public lastIndexUpdate;

    uint256 public totalScaledDebt;
    uint256 public totalPrincipalOut;

    mapping(bytes32 orderId => LoanRecord) public loans;

    uint256 public optimalUtilization;
    uint256 public baseRate;
    uint256 public slope1;
    uint256 public slope2;

    uint256 public reserveFactor;
    uint256 public reserveBalance;

    mapping(address => CooldownState) public cooldowns;

    PendingRateModelConfig private _pendingRateModel;

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event ClaimFunded(bytes32 indexed orderId, uint256 principal, address borrower);
    event ClaimIncreased(bytes32 indexed orderId, uint256 principalIncrease, uint256 totalPrincipal);
    event ClaimPartiallyRepaid(
        bytes32 indexed orderId, uint256 principalPaid, uint256 interestPaid, uint256 remainingPrincipal
    );
    event ClaimFullySettled(bytes32 indexed orderId, uint256 finalInterestPaid);
    event LiquidationSettled(bytes32 indexed orderId, uint256 usdcRecovered);
    event BadDebt(bytes32 indexed orderId, uint256 shortfall);
    event CooldownStarted(address indexed lp, uint256 timestamp);
    event RateUpdated(uint256 newRate, uint256 utilization);
    event IndexUpdated(uint256 newIndex, uint256 timestamp);
    event RateModelUpdateScheduled(
        uint256 optimalUtilization,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 reserveFactor,
        uint256 executeAfter
    );
    event RateModelUpdated(
        uint256 optimalUtilization,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 reserveFactor
    );

    modifier onlyProtocol() {
        require(msg.sender == protocol, "Pool: not protocol");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Pool: not owner");
        _;
    }

    constructor(
        address asset_,
        address protocol_,
        address owner_,
        string memory name_,
        string memory symbol_,
        RateModelConfig memory rateModel_
    ) {
        require(asset_ != address(0), "Pool: bad asset");
        require(protocol_ != address(0), "Pool: bad protocol");
        require(owner_ != address(0), "Pool: bad owner");
        require(bytes(name_).length > 0, "Pool: bad name");
        require(bytes(symbol_).length > 0, "Pool: bad symbol");

        _initializeReentrancyGuard();

        _asset = IERC20(asset_);
        decimals = IERC20Metadata(asset_).decimals();
        protocol = protocol_;
        owner = owner_;
        name = name_;
        symbol = symbol_;

        liquidityIndex = RAY;
        _storeRateModel(rateModel_);
        lastIndexUpdate = block.timestamp;
        currentBorrowRate = _calculateRate(0);
    }

    function asset() public view returns (address) {
        return address(_asset);
    }

    function totalAssets() public view returns (uint256) {
        uint256 outstanding = Math.mulDiv(totalScaledDebt, _currentIndex(), RAY);
        return _idleLiquidity() + outstanding;
    }

    function availableLiquidity() external view returns (uint256) {
        return _idleLiquidity();
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        uint256 total_assets = totalAssets();

        if (supply == 0 || total_assets == 0) {
            return assets;
        }

        return Math.mulDiv(assets, supply, total_assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        uint256 total_assets = totalAssets();

        if (supply == 0 || total_assets == 0) {
            return shares;
        }

        return Math.mulDiv(shares, total_assets, supply);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        uint256 total_assets = totalAssets();

        if (supply == 0 || total_assets == 0) {
            return assets;
        }

        return Math.mulDivUp(assets, supply, total_assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "Pool: amount=0");
        require(receiver != address(0), "Pool: bad receiver");

        _updateIndexAndRate();

        shares = convertToShares(assets);
        require(shares > 0, "Pool: zero shares");

        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "Pool: amount=0");
        require(receiver != address(0), "Pool: bad receiver");

        _updateIndexAndRate();

        uint256 supply = totalSupply;
        uint256 total_assets = totalAssets();

        if (supply == 0 || total_assets == 0) {
            assets = shares;
        } else {
            assets = Math.mulDivUp(shares, total_assets, supply);
        }

        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "Pool: amount=0");
        require(receiver != address(0), "Pool: bad receiver");

        _updateIndexAndRate();

        shares = previewWithdraw(assets);
        _checkCooldown(owner_, shares);
        _checkIdleLiquidity(assets);
        _spendAllowance(owner_, msg.sender, shares);

        delete cooldowns[owner_];
        _burn(owner_, shares);
        _asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "Pool: amount=0");
        require(receiver != address(0), "Pool: bad receiver");

        _updateIndexAndRate();

        _checkCooldown(owner_, shares);
        assets = previewRedeem(shares);
        _checkIdleLiquidity(assets);
        _spendAllowance(owner_, msg.sender, shares);

        delete cooldowns[owner_];
        _burn(owner_, shares);
        _asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function maxWithdraw(address owner_) public view returns (uint256) {
        return Math.min(convertToAssets(balanceOf[owner_]), _idleLiquidity());
    }

    function maxRedeem(address owner_) public view returns (uint256) {
        return Math.min(balanceOf[owner_], convertToShares(_idleLiquidity()));
    }

    function cooldown() external nonReentrant {
        _updateIndexAndRate();

        uint256 shares = balanceOf[msg.sender];
        require(shares > 0, "Pool: no shares");
        require(shares <= type(uint216).max, "Pool: too many shares");

        cooldowns[msg.sender] = CooldownState({timestamp: uint40(block.timestamp), shares: uint216(shares)});

        emit CooldownStarted(msg.sender, block.timestamp);
    }

    function set_rate_model(
        uint256 optimalUtilization_,
        uint256 baseRate_,
        uint256 slope1_,
        uint256 slope2_,
        uint256 reserveFactor_
    ) external onlyOwner {
        RateModelConfig memory rateModel = RateModelConfig({
            optimalUtilization: optimalUtilization_,
            baseRate: baseRate_,
            slope1: slope1_,
            slope2: slope2_,
            reserveFactor: reserveFactor_
        });
        _validateRateModel(rateModel);

        uint256 executeAfter = block.timestamp + CONFIG_DELAY;
        _pendingRateModel = PendingRateModelConfig({
            optimalUtilization: optimalUtilization_,
            baseRate: baseRate_,
            slope1: slope1_,
            slope2: slope2_,
            reserveFactor: reserveFactor_,
            executeAfter: executeAfter
        });

        emit RateModelUpdateScheduled(
            optimalUtilization_, baseRate_, slope1_, slope2_, reserveFactor_, executeAfter
        );
    }

    function apply_rate_model() external onlyOwner {
        uint256 executeAfter = _pendingRateModel.executeAfter;
        require(executeAfter != 0, "Pool: change not scheduled");
        require(block.timestamp >= executeAfter, "Pool: config timelock");

        _updateIndexAndRate();

        RateModelConfig memory rateModel = RateModelConfig({
            optimalUtilization: _pendingRateModel.optimalUtilization,
            baseRate: _pendingRateModel.baseRate,
            slope1: _pendingRateModel.slope1,
            slope2: _pendingRateModel.slope2,
            reserveFactor: _pendingRateModel.reserveFactor
        });

        delete _pendingRateModel;
        _storeRateModel(rateModel);

        uint256 util = utilizationRate();
        currentBorrowRate = _calculateRate(util);

        emit RateModelUpdated(
            rateModel.optimalUtilization,
            rateModel.baseRate,
            rateModel.slope1,
            rateModel.slope2,
            rateModel.reserveFactor
        );
        emit RateUpdated(currentBorrowRate, util);
    }

    function fundClaim(bytes32 orderId, uint256 principal, address borrower) external onlyProtocol nonReentrant {
        require(orderId != bytes32(0), "Pool: bad order");
        require(principal > 0, "Pool: amount=0");
        require(borrower != address(0), "Pool: bad borrower");
        require(!loans[orderId].active, "Pool: loan active");

        _updateIndexAndRate();
        require(principal <= _idleLiquidity(), "Pool: insufficient idle");

        uint256 scaled = Math.mulDiv(principal, RAY, liquidityIndex);
        require(scaled > 0, "Pool: zero debt");

        loans[orderId] = LoanRecord({scaledPrincipal: scaled, rawPrincipal: principal, borrower: borrower, active: true});

        totalScaledDebt += scaled;
        totalPrincipalOut += principal;

        _asset.safeTransfer(protocol, principal);

        emit ClaimFunded(orderId, principal, borrower);
    }

    function increaseClaim(bytes32 orderId, uint256 principalIncrease) external onlyProtocol nonReentrant {
        require(orderId != bytes32(0), "Pool: bad order");
        require(principalIncrease > 0, "Pool: amount=0");

        LoanRecord storage loan = loans[orderId];
        require(loan.active, "Pool: not active");

        _updateIndexAndRate();
        require(principalIncrease <= _idleLiquidity(), "Pool: insufficient idle");

        uint256 scaledIncrease = Math.mulDiv(principalIncrease, RAY, liquidityIndex);
        require(scaledIncrease > 0, "Pool: zero debt");

        loan.scaledPrincipal += scaledIncrease;
        loan.rawPrincipal += principalIncrease;
        totalScaledDebt += scaledIncrease;
        totalPrincipalOut += principalIncrease;

        _asset.safeTransfer(protocol, principalIncrease);

        emit ClaimIncreased(orderId, principalIncrease, loan.rawPrincipal);
    }

    function settleRepayment(bytes32 orderId, uint256 amount) external onlyProtocol nonReentrant {
        require(amount > 0, "Pool: amount=0");

        LoanRecord storage loan = loans[orderId];
        require(loan.active, "Pool: not active");

        _updateIndexAndRate();

        uint256 current_debt = _currentDebt(loan, liquidityIndex);
        require(amount <= current_debt, "Pool: overpayment");

        uint256 accrued_interest = current_debt - loan.rawPrincipal;
        uint256 interest_paid = Math.min(amount, accrued_interest);
        uint256 principal_paid = amount - interest_paid;
        uint256 scaled_reduction;

        if (amount == current_debt) {
            scaled_reduction = loan.scaledPrincipal;
        } else {
            scaled_reduction = Math.mulDiv(amount, RAY, liquidityIndex);
        }

        uint256 to_reserve = Math.mulDiv(interest_paid, reserveFactor, RAY);
        reserveBalance += to_reserve;

        totalScaledDebt -= scaled_reduction;
        loan.scaledPrincipal -= scaled_reduction;

        if (principal_paid > 0) {
            totalPrincipalOut -= principal_paid;
            loan.rawPrincipal -= principal_paid;
        }

        if (loan.rawPrincipal == 0) {
            loan.active = false;
            emit ClaimFullySettled(orderId, interest_paid);
        } else {
            emit ClaimPartiallyRepaid(orderId, principal_paid, interest_paid, loan.rawPrincipal);
        }
    }

    function settleLiquidation(bytes32 orderId, uint256 usdcRecovered) external onlyProtocol nonReentrant {
        LoanRecord storage loan = loans[orderId];
        require(loan.active, "Pool: not active");

        _updateIndexAndRate();

        uint256 current_debt = _currentDebt(loan, liquidityIndex);
        require(usdcRecovered <= current_debt, "Pool: over recovery");

        totalScaledDebt -= loan.scaledPrincipal;
        totalPrincipalOut -= loan.rawPrincipal;

        loan.scaledPrincipal = 0;
        loan.rawPrincipal = 0;
        loan.active = false;

        if (usdcRecovered < current_debt) {
            uint256 shortfall = current_debt - usdcRecovered;

            if (reserveBalance >= shortfall) {
                reserveBalance -= shortfall;
            } else {
                reserveBalance = 0;
            }

            emit BadDebt(orderId, shortfall);
        }

        emit LiquidationSettled(orderId, usdcRecovered);
    }

    function currentDebt(bytes32 orderId) external view returns (uint256) {
        LoanRecord storage loan = loans[orderId];

        if (!loan.active) {
            return 0;
        }

        return _currentDebt(loan, _currentIndex());
    }

    function remainingPrincipal(bytes32 orderId) external view returns (uint256) {
        return loans[orderId].rawPrincipal;
    }

    function utilizationRate() public view returns (uint256) {
        uint256 supplied = totalAssets();

        if (supplied == 0) {
            return 0;
        }

        return Math.min(Math.mulDiv(totalPrincipalOut, RAY, supplied), RAY);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from_, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from_, msg.sender, amount);
        _transfer(from_, to, amount);
        return true;
    }

    function _currentIndex() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastIndexUpdate;

        if (elapsed == 0) {
            return liquidityIndex;
        }

        uint256 growth = Math.mulDiv(currentBorrowRate, elapsed, SECONDS_PER_YEAR);
        return Math.mulDiv(liquidityIndex, RAY + growth, RAY);
    }

    function _currentDebt(LoanRecord storage loan, uint256 index) internal view returns (uint256) {
        return Math.mulDiv(loan.scaledPrincipal, index, RAY);
    }

    function _calculateRate(uint256 util) internal view returns (uint256) {
        if (util <= optimalUtilization) {
            return baseRate + Math.mulDiv(util, slope1, optimalUtilization);
        }

        uint256 excess_util = util - optimalUtilization;
        uint256 max_excess = RAY - optimalUtilization;
        return baseRate + slope1 + Math.mulDiv(excess_util, slope2, max_excess);
    }

    function _storeRateModel(RateModelConfig memory rateModel) internal {
        _validateRateModel(rateModel);
        optimalUtilization = rateModel.optimalUtilization;
        baseRate = rateModel.baseRate;
        slope1 = rateModel.slope1;
        slope2 = rateModel.slope2;
        reserveFactor = rateModel.reserveFactor;
    }

    function _validateRateModel(RateModelConfig memory rateModel) internal pure {
        require(rateModel.optimalUtilization > 0 && rateModel.optimalUtilization < RAY, "Pool: bad optimal");
        require(rateModel.reserveFactor <= RAY, "Pool: bad reserve factor");
    }

    function _updateIndexAndRate() internal {
        uint256 next_index = _currentIndex();
        liquidityIndex = next_index;
        lastIndexUpdate = block.timestamp;

        uint256 util = utilizationRate();
        currentBorrowRate = _calculateRate(util);

        emit IndexUpdated(next_index, block.timestamp);
        emit RateUpdated(currentBorrowRate, util);
    }

    function _idleLiquidity() internal view returns (uint256) {
        return _asset.balanceOf(address(this)) - reserveBalance;
    }

    function _checkCooldown(address owner_, uint256 shares) internal view {
        CooldownState memory cd = cooldowns[owner_];
        require(cd.timestamp != 0, "Pool: cooldown not initiated");
        require(block.timestamp >= cd.timestamp + COOLDOWN_PERIOD, "Pool: cooldown not elapsed");
        require(block.timestamp <= cd.timestamp + COOLDOWN_PERIOD + WITHDRAW_WINDOW, "Pool: window expired");
        require(shares <= cd.shares, "Pool: exceeds cooldown shares");
    }

    function _checkIdleLiquidity(uint256 assets) internal view {
        require(assets <= _idleLiquidity(), "Pool: insufficient idle liquidity");
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from_, uint256 amount) internal {
        balanceOf[from_] -= amount;
        totalSupply -= amount;
        emit Transfer(from_, address(0), amount);
    }

    function _transfer(address from_, address to, uint256 amount) internal {
        require(to != address(0), "Pool: bad to");
        balanceOf[from_] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from_, to, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 amount) internal {
        if (spender == owner_) {
            return;
        }

        uint256 allowed = allowance[owner_][spender];

        if (allowed != type(uint256).max) {
            allowance[owner_][spender] = allowed - amount;
            emit Approval(owner_, spender, allowance[owner_][spender]);
        }
    }
}
