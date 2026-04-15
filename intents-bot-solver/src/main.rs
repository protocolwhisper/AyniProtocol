use anyhow::{Context, Result};
use async_trait::async_trait;
use dotenvy::dotenv;
use ethers::abi::{Token, encode};
use ethers::contract::abigen;
use ethers::middleware::SignerMiddleware;
use ethers::providers::{Http, Middleware, Provider};
use ethers::signers::{LocalWallet, Signer};
use ethers::types::{Address, BlockNumber, Bytes, Filter, H256, U64, U256};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::env;
use std::path::Path;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::fs;
use tracing::{debug, info, warn};

abigen!(
    AyniProtocolContract,
    r#"[
        function get_debt_position(bytes32) view returns (address,address,address,address,address,uint256,uint256,uint256,uint256,bytes32,uint8)
    ]"#
);

abigen!(
    DestinationSettlerContract,
    r#"[
        function fill(bytes32 orderId, bytes originData, bytes fillerData)
    ]"#
);

abigen!(
    Erc20Contract,
    r#"[
        function balanceOf(address owner) view returns (uint256)
        function allowance(address owner, address spender) view returns (uint256)
        function approve(address spender, uint256 amount) returns (bool)
        function symbol() view returns (string)
        function decimals() view returns (uint8)
    ]"#
);

const CLAIM_OPEN_STATUS: u8 = 1;

#[derive(Debug, Clone)]
struct Config {
    rpc_url: String,
    chain_id: u64,
    ayni_protocol_address: Address,
    destination_settler_address: Address,
    usdc_token_address: Address,
    solver_private_key: String,
    poll_interval_secs: u64,
    max_block_range: u64,
    start_block: u64,
    last_block_file: String,
    min_usdc_balance: U256,
    log_level: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Cursor {
    last_block: u64,
}

#[derive(Debug, Clone)]
struct DebtPositionSnapshot {
    borrower: Address,
    recipient: Address,
    debt_asset: Address,
    principal: U256,
    fill_deadline: u64,
    status: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProcessOutcome {
    Filled,
    Skipped,
}

#[async_trait]
trait SolverBackend {
    fn solver_address(&self) -> Address;
    async fn get_debt_position(&self, order_id: H256) -> Result<DebtPositionSnapshot>;
    async fn usdc_balance(&self, owner: Address) -> Result<U256>;
    async fn allowance(&self, owner: Address, spender: Address) -> Result<U256>;
    async fn approve_max(&self, spender: Address) -> Result<()>;
    async fn fill_claim(&self, order_id: H256, origin_data: Bytes) -> Result<bool>;
}

struct EvmBackend<M: Middleware + 'static> {
    protocol: AyniProtocolContract<M>,
    destination: DestinationSettlerContract<M>,
    usdc: Erc20Contract<M>,
    solver_address: Address,
}

#[async_trait]
impl<M: Middleware + 'static> SolverBackend for EvmBackend<M> {
    fn solver_address(&self) -> Address {
        self.solver_address
    }

    async fn get_debt_position(&self, order_id: H256) -> Result<DebtPositionSnapshot> {
        let (
            _vault,
            borrower,
            recipient,
            _collateral_token,
            debt_asset,
            principal,
            _protocol_fee_bps,
            fill_deadline,
            _filled_at,
            _expected_fill_hash,
            status,
        ) = self.protocol.get_debt_position(order_id.into()).call().await?;

        Ok(DebtPositionSnapshot {
            borrower,
            recipient,
            debt_asset,
            principal,
            fill_deadline: fill_deadline.as_u64(),
            status,
        })
    }

    async fn usdc_balance(&self, owner: Address) -> Result<U256> {
        Ok(self.usdc.balance_of(owner).call().await?)
    }

    async fn allowance(&self, owner: Address, spender: Address) -> Result<U256> {
        Ok(self.usdc.allowance(owner, spender).call().await?)
    }

    async fn approve_max(&self, spender: Address) -> Result<()> {
        let approve_call = self.usdc.approve(spender, U256::MAX);
        let pending = approve_call
            .send()
            .await
            .context("failed to submit approve transaction")?;
        let receipt = pending
            .await
            .context("failed waiting for approve transaction")?;

        if receipt.as_ref().and_then(|r| r.status) != Some(U64::from(1u64)) {
            anyhow::bail!("approve transaction failed");
        }
        Ok(())
    }

    async fn fill_claim(&self, order_id: H256, origin_data: Bytes) -> Result<bool> {
        let fill_call = self.destination.fill(order_id.into(), origin_data, Bytes::new());
        let pending_tx = fill_call
            .send()
            .await
            .context("failed to submit fill transaction")?;

        let receipt_opt = pending_tx.await.context("failed waiting for fill receipt")?;
        let Some(receipt) = receipt_opt else {
            warn!(order_id = %order_id, "fill transaction dropped from mempool");
            return Ok(false);
        };

        if receipt.status == Some(U64::from(1u64)) {
            info!(
                order_id = %order_id,
                tx_hash = %receipt.transaction_hash,
                "fill transaction succeeded"
            );
            return Ok(true);
        }

        warn!(
            order_id = %order_id,
            tx_hash = %receipt.transaction_hash,
            "fill transaction reverted"
        );
        Ok(false)
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = dotenv();
    let config = Config::from_env()?;

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| config.log_level.parse().unwrap_or_default()),
        )
        .json()
        .init();

    let provider =
        Provider::<Http>::try_from(config.rpc_url.as_str()).context("failed to create RPC provider")?;
    let provider = Arc::new(provider);

    let wallet: LocalWallet = config
        .solver_private_key
        .parse::<LocalWallet>()
        .context("SOLVER_PRIVATE_KEY is invalid")?
        .with_chain_id(config.chain_id);
    let solver_address = wallet.address();
    let client = Arc::new(SignerMiddleware::new(provider.clone(), wallet));

    let protocol = AyniProtocolContract::new(config.ayni_protocol_address, client.clone());
    let destination = DestinationSettlerContract::new(config.destination_settler_address, client.clone());
    let usdc = Erc20Contract::new(config.usdc_token_address, client.clone());

    let usdc_symbol = usdc.symbol().call().await.unwrap_or_else(|_| "USDC".to_string());
    let usdc_decimals = usdc.decimals().call().await.unwrap_or(6u8);

    let mut from_block = resolve_start_block(&config, provider.as_ref()).await?;
    let mut seen_order_ids = HashSet::<H256>::new();

    info!(
        solver = %solver_address,
        chain_id = config.chain_id,
        protocol = %config.ayni_protocol_address,
        destination_settler = %config.destination_settler_address,
        usdc = %config.usdc_token_address,
        usdc_symbol = %usdc_symbol,
        usdc_decimals = usdc_decimals,
        start_block = from_block,
        "starting ayni intents bot solver"
    );

    loop {
        let head = provider
            .get_block_number()
            .await
            .context("failed to fetch latest block")?
            .as_u64();

        if from_block > head {
            tokio::time::sleep(Duration::from_secs(config.poll_interval_secs)).await;
            continue;
        }

        let to_block = std::cmp::min(
            from_block.saturating_add(config.max_block_range).saturating_sub(1),
            head,
        );

        let filter = Filter::new()
            .address(config.ayni_protocol_address)
            .from_block(BlockNumber::Number(U64::from(from_block)))
            .to_block(BlockNumber::Number(U64::from(to_block)));

        let logs = provider.get_logs(&filter).await.with_context(|| {
            format!("failed to fetch logs for range {from_block}..={to_block}")
        })?;
        debug!(from_block, to_block, logs = logs.len(), "fetched logs");

        for log in logs {
            let Some(order_id) = extract_order_id(&log) else {
                continue;
            };

            if seen_order_ids.contains(&order_id) {
                continue;
            }

            if let Err(err) = try_fill_order(
                &config,
                &EvmBackend {
                    protocol: protocol.clone(),
                    destination: destination.clone(),
                    usdc: usdc.clone(),
                    solver_address,
                },
                order_id,
            )
            .await
            {
                warn!(order_id = %order_id, error = %err, "order processing failed");
            }

            seen_order_ids.insert(order_id);
        }

        persist_cursor(&config.last_block_file, to_block).await?;
        from_block = to_block.saturating_add(1);
        tokio::time::sleep(Duration::from_secs(config.poll_interval_secs)).await;
    }
}

fn extract_order_id(log: &ethers::types::Log) -> Option<H256> {
    // We intentionally do not decode all event signatures; AyniProtocol events that
    // include order IDs emit them in topic[1], and non-order logs are filtered out
    // later by get_debt_position status checks.
    log.topics.get(1).copied()
}

async fn try_fill_order<M: Middleware + 'static>(
    config: &Config,
    backend: &EvmBackend<M>,
    order_id: H256,
) -> Result<()> {
    let _ = process_order(config, backend, order_id).await?;
    Ok(())
}

async fn process_order<B: SolverBackend>(
    config: &Config,
    backend: &B,
    order_id: H256,
) -> Result<ProcessOutcome> {
    let snapshot = backend.get_debt_position(order_id).await?;

    if snapshot.status != CLAIM_OPEN_STATUS {
        return Ok(ProcessOutcome::Skipped);
    }

    let now_secs = current_unix_secs();
    if snapshot.fill_deadline <= now_secs {
        warn!(order_id = %order_id, "skipping expired open claim");
        return Ok(ProcessOutcome::Skipped);
    }

    if snapshot.debt_asset != config.usdc_token_address {
        debug!(
            order_id = %order_id,
            debt_asset = %snapshot.debt_asset,
            expected_usdc = %config.usdc_token_address,
            "skipping non-USDC claim"
        );
        return Ok(ProcessOutcome::Skipped);
    }

    if snapshot.principal.is_zero() {
        return Ok(ProcessOutcome::Skipped);
    }

    let solver_address = backend.solver_address();
    let balance = backend.usdc_balance(solver_address).await?;
    if balance < snapshot.principal {
        warn!(
            order_id = %order_id,
            principal = %snapshot.principal,
            balance = %balance,
            "insufficient USDC balance to fill claim"
        );
        return Ok(ProcessOutcome::Skipped);
    }

    if balance < config.min_usdc_balance {
        warn!(
            order_id = %order_id,
            balance = %balance,
            min_required = %config.min_usdc_balance,
            "USDC balance below MIN_USDC_BALANCE guard; skipping fill"
        );
        return Ok(ProcessOutcome::Skipped);
    }

    let current_allowance = backend
        .allowance(
            solver_address,
            config.destination_settler_address,
        )
        .await?;
    if current_allowance < snapshot.principal {
        info!(
            spender = %config.destination_settler_address,
            previous_allowance = %current_allowance,
            needed_amount = %snapshot.principal,
            "updating USDC allowance for destination settler"
        );
        backend.approve_max(config.destination_settler_address).await?;
    }

    let origin_data = encode_fill_origin_data(
        snapshot.recipient,
        snapshot.debt_asset,
        snapshot.principal,
    );
    let fill_succeeded = backend.fill_claim(order_id, origin_data).await?;
    if fill_succeeded {
        info!(
            order_id = %order_id,
            borrower = %snapshot.borrower,
            recipient = %snapshot.recipient,
            amount = %snapshot.principal,
            "claim filled successfully"
        );
        return Ok(ProcessOutcome::Filled);
    } else {
        return Ok(ProcessOutcome::Skipped);
    }
}

fn encode_fill_origin_data(recipient: Address, debt_asset: Address, amount: U256) -> Bytes {
    let encoded = encode(&[Token::Tuple(vec![
        Token::Address(recipient),
        Token::Address(debt_asset),
        Token::Uint(amount),
    ])]);
    Bytes::from(encoded)
}

fn current_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

async fn resolve_start_block(config: &Config, provider: &Provider<Http>) -> Result<u64> {
    let persisted = read_cursor(&config.last_block_file).await?;
    if persisted > 0 {
        return Ok(persisted.saturating_add(1));
    }

    if config.start_block > 0 {
        return Ok(config.start_block);
    }

    let latest = provider
        .get_block_number()
        .await
        .context("failed to fetch latest block")?
        .as_u64();
    Ok(latest.saturating_sub(100))
}

async fn read_cursor(path: &str) -> Result<u64> {
    if !Path::new(path).exists() {
        return Ok(0);
    }

    let raw = fs::read_to_string(path)
        .await
        .with_context(|| format!("failed to read cursor file {path}"))?;
    let cursor: Cursor =
        serde_json::from_str(&raw).with_context(|| format!("invalid cursor JSON in {path}"))?;
    Ok(cursor.last_block)
}

async fn persist_cursor(path: &str, block: u64) -> Result<()> {
    let tmp_path = format!("{path}.tmp");
    let payload = serde_json::to_string_pretty(&Cursor { last_block: block })
        .context("failed to serialize cursor")?;
    fs::write(&tmp_path, payload)
        .await
        .with_context(|| format!("failed to write tmp cursor {tmp_path}"))?;
    fs::rename(&tmp_path, path)
        .await
        .with_context(|| format!("failed to atomically move cursor file into place {path}"))?;
    Ok(())
}

impl Config {
    fn from_env() -> Result<Self> {
        Ok(Self {
            rpc_url: require("RPC_URL")?,
            chain_id: env_parse("CHAIN_ID", "11155111")?,
            ayni_protocol_address: parse_address("AYNI_PROTOCOL_ADDRESS")?,
            destination_settler_address: parse_address("DESTINATION_SETTLER_ADDRESS")?,
            usdc_token_address: parse_address("USDC_TOKEN_ADDRESS")?,
            solver_private_key: require("SOLVER_PRIVATE_KEY")?,
            poll_interval_secs: env_parse("POLL_INTERVAL_SECS", "5")?,
            max_block_range: env_parse("MAX_BLOCK_RANGE", "200")?,
            start_block: env_parse("START_BLOCK", "0")?,
            last_block_file: env::var("LAST_BLOCK_FILE")
                .unwrap_or_else(|_| "./last_block.json".to_string()),
            min_usdc_balance: env_u256("MIN_USDC_BALANCE", U256::zero())?,
            log_level: env::var("LOG_LEVEL").unwrap_or_else(|_| "info".to_string()),
        })
    }
}

fn require(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("{name} is required but not set"))
}

fn parse_address(name: &str) -> Result<Address> {
    let raw = require(name)?;
    Address::from_str(raw.trim()).with_context(|| format!("{name} is not a valid address: {raw}"))
}

fn env_parse<T>(name: &str, default: &str) -> Result<T>
where
    T: FromStr,
    T::Err: std::fmt::Display,
{
    let raw = env::var(name).unwrap_or_else(|_| default.to_string());
    raw.parse::<T>()
        .map_err(|e| anyhow::anyhow!("{name} has invalid value `{raw}`: {e}"))
}

fn env_u256(name: &str, default: U256) -> Result<U256> {
    let raw = env::var(name).unwrap_or_else(|_| default.to_string());
    U256::from_dec_str(raw.trim()).with_context(|| format!("{name} has invalid U256 decimal: {raw}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};
    use tokio::sync::Mutex;

    #[derive(Clone)]
    struct MockBackend {
        solver: Address,
        snapshot: DebtPositionSnapshot,
        balance: U256,
        allowance: Arc<Mutex<U256>>,
        approve_calls: Arc<Mutex<u32>>,
        fill_calls: Arc<Mutex<u32>>,
        fill_success: bool,
    }

    impl MockBackend {
        fn new(snapshot: DebtPositionSnapshot, balance: U256, allowance: U256, fill_success: bool) -> Self {
            Self {
                solver: Address::from_low_u64_be(7),
                snapshot,
                balance,
                allowance: Arc::new(Mutex::new(allowance)),
                approve_calls: Arc::new(Mutex::new(0)),
                fill_calls: Arc::new(Mutex::new(0)),
                fill_success,
            }
        }
    }

    #[async_trait]
    impl SolverBackend for MockBackend {
        fn solver_address(&self) -> Address {
            self.solver
        }

        async fn get_debt_position(&self, _order_id: H256) -> Result<DebtPositionSnapshot> {
            Ok(self.snapshot.clone())
        }

        async fn usdc_balance(&self, _owner: Address) -> Result<U256> {
            Ok(self.balance)
        }

        async fn allowance(&self, _owner: Address, _spender: Address) -> Result<U256> {
            Ok(*self.allowance.lock().await)
        }

        async fn approve_max(&self, _spender: Address) -> Result<()> {
            *self.approve_calls.lock().await += 1;
            *self.allowance.lock().await = U256::MAX;
            Ok(())
        }

        async fn fill_claim(&self, _order_id: H256, _origin_data: Bytes) -> Result<bool> {
            *self.fill_calls.lock().await += 1;
            Ok(self.fill_success)
        }
    }

    fn test_config(usdc: Address) -> Config {
        Config {
            rpc_url: "http://localhost:8545".to_string(),
            chain_id: 11155111,
            ayni_protocol_address: Address::from_low_u64_be(1),
            destination_settler_address: Address::from_low_u64_be(2),
            usdc_token_address: usdc,
            solver_private_key: "0x01".to_string(),
            poll_interval_secs: 1,
            max_block_range: 100,
            start_block: 0,
            last_block_file: "./test-cursor.json".to_string(),
            min_usdc_balance: U256::zero(),
            log_level: "info".to_string(),
        }
    }

    fn now_plus_secs(delta: u64) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
            + delta
    }

    #[tokio::test]
    async fn e2e_fills_open_usdc_claim() {
        let usdc = Address::from_low_u64_be(100);
        let order_id = H256::from_low_u64_be(11);
        let snapshot = DebtPositionSnapshot {
            borrower: Address::from_low_u64_be(10),
            recipient: Address::from_low_u64_be(20),
            debt_asset: usdc,
            principal: U256::from(1_000_000u64),
            fill_deadline: now_plus_secs(300),
            status: CLAIM_OPEN_STATUS,
        };

        let backend = MockBackend::new(
            snapshot,
            U256::from(10_000_000u64),
            U256::zero(),
            true,
        );
        let config = test_config(usdc);

        let outcome = process_order(&config, &backend, order_id).await.unwrap();
        assert_eq!(outcome, ProcessOutcome::Filled);
        assert_eq!(*backend.approve_calls.lock().await, 1);
        assert_eq!(*backend.fill_calls.lock().await, 1);
    }

    #[tokio::test]
    async fn e2e_skips_non_usdc_claim() {
        let usdc = Address::from_low_u64_be(100);
        let order_id = H256::from_low_u64_be(12);
        let snapshot = DebtPositionSnapshot {
            borrower: Address::from_low_u64_be(10),
            recipient: Address::from_low_u64_be(20),
            debt_asset: Address::from_low_u64_be(999),
            principal: U256::from(1_000_000u64),
            fill_deadline: now_plus_secs(300),
            status: CLAIM_OPEN_STATUS,
        };

        let backend = MockBackend::new(
            snapshot,
            U256::from(10_000_000u64),
            U256::MAX,
            true,
        );
        let config = test_config(usdc);

        let outcome = process_order(&config, &backend, order_id).await.unwrap();
        assert_eq!(outcome, ProcessOutcome::Skipped);
        assert_eq!(*backend.approve_calls.lock().await, 0);
        assert_eq!(*backend.fill_calls.lock().await, 0);
    }

    #[tokio::test]
    async fn e2e_skips_when_balance_insufficient() {
        let usdc = Address::from_low_u64_be(100);
        let order_id = H256::from_low_u64_be(13);
        let snapshot = DebtPositionSnapshot {
            borrower: Address::from_low_u64_be(10),
            recipient: Address::from_low_u64_be(20),
            debt_asset: usdc,
            principal: U256::from(5_000_000u64),
            fill_deadline: now_plus_secs(300),
            status: CLAIM_OPEN_STATUS,
        };

        let backend = MockBackend::new(snapshot, U256::from(1_000_000u64), U256::MAX, true);
        let config = test_config(usdc);

        let outcome = process_order(&config, &backend, order_id).await.unwrap();
        assert_eq!(outcome, ProcessOutcome::Skipped);
        assert_eq!(*backend.approve_calls.lock().await, 0);
        assert_eq!(*backend.fill_calls.lock().await, 0);
    }
}
