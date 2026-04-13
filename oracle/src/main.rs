use anyhow::{Context, Result, bail};
use dotenvy::dotenv;
use k256::ecdsa::SigningKey;
use reqwest::blocking::Client;
use serde::Deserialize;
use serde::Serialize;
use sha3::{Digest, Keccak256};
use std::{env, fs, path::PathBuf};

#[derive(Debug, Deserialize)]
struct SimplePriceResponse {
    litecoin: LitecoinPrice,
}

#[derive(Debug, Deserialize)]
struct LitecoinPrice {
    usd: f64,
    last_updated_at: Option<u64>,
}

#[derive(Debug, Serialize)]
struct GeneratedOwner {
    address: String,
    private_key: String,
}

fn main() -> Result<()> {
    let _ = dotenv();

    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("owner") => generate_owner(),
        Some("deploy-command") => print_deploy_command(),
        Some(other) => bail!("unknown command: {other}"),
        None => print_price(),
    }
}

fn print_price() -> Result<()> {
    let url = env_var("ORACLE_PRICE_URL")?;
    let decimals = env_u32("ORACLE_DECIMALS").unwrap_or(8);

    let client = Client::builder()
        .user_agent("ayni-oracle/0.1.0")
        .build()
        .context("failed to build HTTP client")?;

    let response = client
        .get(&url)
        .send()
        .with_context(|| format!("failed to fetch oracle price from {url}"))?
        .error_for_status()
        .with_context(|| format!("oracle endpoint returned error status for {url}"))?
        .json::<SimplePriceResponse>()
        .context("failed to decode oracle price response")?;

    let price = response.litecoin.usd;
    if !price.is_finite() || price <= 0.0 {
        bail!("received invalid litecoin price: {price}");
    }

    let scaled = scale_price(price, decimals)?;

    println!("Ayni Oracle Helper");
    println!("source_url={url}");
    println!("pair=LTC/USD (used as LTC/USDC for testing)");
    println!("price_usd={price}");
    println!("oracle_decimals={decimals}");
    println!("scaled_price={scaled}");
    match response.litecoin.last_updated_at {
        Some(ts) => println!("last_updated_at={ts}"),
        None => println!("last_updated_at=unknown"),
    }

    print_cast_commands(scaled);

    Ok(())
}

fn generate_owner() -> Result<()> {
    let signing_key = SigningKey::random(&mut k256::elliptic_curve::rand_core::OsRng);
    let private_bytes = signing_key.to_bytes();
    let verifying_key = signing_key.verifying_key();
    let public_key = verifying_key.to_encoded_point(false);
    let public_key_bytes = public_key.as_bytes();

    let hash = Keccak256::digest(&public_key_bytes[1..]);
    let address = format!("0x{}", hex::encode(&hash[12..]));
    let private_key = format!("0x{}", hex::encode(private_bytes));

    let generated = GeneratedOwner {
        address: address.clone(),
        private_key,
    };

    let output = serde_json::to_string_pretty(&generated).context("failed to encode generated owner")?;
    let path = generated_owner_path();
    fs::write(&path, output).with_context(|| format!("failed to write {}", path.display()))?;

    println!("Generated oracle owner");
    println!("address={address}");
    println!("saved_to={}", path.display());
    println!("Fund this address with gas before using it as deployer or oracle owner.");

    Ok(())
}

fn print_deploy_command() -> Result<()> {
    let owner = env_var("OWNER_ADDRESS")?;
    let feed = env_var("FEED_ADDRESS")?;
    let rpc_url = env_var("RPC_URL")?;
    let account = env_var("ACCOUNT")?;

    println!("Deploy command:");
    println!(
        "forge script script/DeployOracle.s.sol:DeployOracle --sig \"run(address,address)\" {owner} {feed} --rpc-url {rpc_url} --account {account} --broadcast"
    );
    println!();
    println!("Notes:");
    println!("oracle_contract_needs_gas=false");
    println!("deployer_needs_gas=true");
    println!("owner_needs_gas_only_for_admin_transactions=true");

    Ok(())
}

fn scale_price(price: f64, decimals: u32) -> Result<u128> {
    let factor = 10_u128
        .checked_pow(decimals)
        .context("oracle decimals are too large to scale safely")?;

    let scaled = (price * factor as f64).round();
    if !scaled.is_finite() || scaled < 0.0 {
        bail!("scaled price is invalid: {scaled}");
    }

    Ok(scaled as u128)
}

fn print_cast_commands(scaled_price: u128) {
    let oracle = env::var("ORACLE_CONTRACT_ADDRESS").ok();
    let rpc_url = env::var("RPC_URL").ok();
    let account = env::var("ACCOUNT").ok();

    let (Some(oracle), Some(rpc_url), Some(account)) = (oracle, rpc_url, account) else {
        return;
    };

    println!();
    println!("Suggested cast commands:");
    println!(
        "cast send {oracle} \"set_fallback_price(uint256)\" {scaled_price} --rpc-url {rpc_url} --account {account}"
    );
    println!(
        "cast send {oracle} \"apply_fallback_price()\" --rpc-url {rpc_url} --account {account}"
    );
    println!(
        "cast send {oracle} \"set_use_fallback(bool)\" true --rpc-url {rpc_url} --account {account}"
    );
    println!(
        "cast send {oracle} \"apply_use_fallback()\" --rpc-url {rpc_url} --account {account}"
    );
}

fn env_var(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("missing required env var {name}"))
}

fn env_u32(name: &str) -> Result<u32> {
    let value = env_var(name)?;
    value
        .parse::<u32>()
        .with_context(|| format!("invalid integer for {name}: {value}"))
}

fn generated_owner_path() -> PathBuf {
    PathBuf::from("generated-owner.json")
}
