use anyhow::{Context, Result, bail};
use dotenvy::dotenv;
use k256::ecdsa::SigningKey;
use k256::elliptic_curve::rand_core::OsRng;
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
    let (url, decimals, response, scaled) = fetch_scaled_price()?;

    println!("Ayni Oracle Helper");
    println!("source_url={url}");
    println!("pair=LTC/USD (used as LTC/USDC for testing)");
    println!("price_usd={}", response.litecoin.usd);
    println!("oracle_decimals={decimals}");
    println!("scaled_price={scaled}");
    match response.litecoin.last_updated_at {
        Some(ts) => println!("last_updated_at={ts}"),
        None => println!("last_updated_at=unknown"),
    }
    if let Ok(address) = owner_address_from_private_key_env() {
        println!("signer_address={address}");
    }

    print_cast_commands(scaled);

    Ok(())
}

fn generate_owner() -> Result<()> {
    let signing_key = SigningKey::random(&mut OsRng);
    let private_bytes = signing_key.to_bytes();
    let address = signing_key_to_address(&signing_key);
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
    let owner = owner_address_from_private_key_env()?;
    let feed = env_var("FEED_ADDRESS")?;
    let rpc_url = env_var("RPC_URL")?;
    let private_key = env_var("PRIVATE_KEY")?;
    let (_, _, _, scaled_price) = fetch_scaled_price()?;
    let decimals = env_u32("ORACLE_DECIMALS").unwrap_or(8);

    println!("Deploy command:");
    println!(
        "forge script script/DeployOracle.s.sol:DeployOracle --sig \"runWithManualFeed(address,int256,uint8)\" {owner} {scaled_price} {decimals} --rpc-url {rpc_url} --private-key {private_key} --broadcast"
    );
    println!();
    println!("Notes:");
    println!("oracle_contract_needs_gas=false");
    println!("deployer_needs_gas=true");
    println!("owner_needs_gas_only_for_admin_transactions=true");
    println!("existing_feed_address={feed}");

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
    let feed = env::var("FEED_ADDRESS").ok();
    let rpc_url = env::var("RPC_URL").ok();
    let private_key = env::var("PRIVATE_KEY").ok();

    if let (Some(feed), Some(rpc_url), Some(private_key)) = (feed, rpc_url.clone(), private_key.clone()) {
        println!();
        println!("Suggested feed update command:");
        println!(
            "cast send {feed} \"setPrice(int256)\" {scaled_price} --rpc-url {rpc_url} --private-key {private_key}"
        );
    }

    let (Some(oracle), Some(rpc_url), Some(private_key)) = (oracle, rpc_url, private_key) else {
        return;
    };

    println!();
    println!("Suggested cast commands:");
    println!(
        "cast send {oracle} \"set_fallback_price(uint256)\" {scaled_price} --rpc-url {rpc_url} --private-key {private_key}"
    );
    println!(
        "cast send {oracle} \"apply_fallback_price()\" --rpc-url {rpc_url} --private-key {private_key}"
    );
    println!(
        "cast send {oracle} \"set_use_fallback(bool)\" true --rpc-url {rpc_url} --private-key {private_key}"
    );
    println!(
        "cast send {oracle} \"apply_use_fallback()\" --rpc-url {rpc_url} --private-key {private_key}"
    );
}

fn fetch_scaled_price() -> Result<(String, u32, SimplePriceResponse, u128)> {
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
    Ok((url, decimals, response, scaled))
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

fn owner_address_from_private_key_env() -> Result<String> {
    let signing_key = signing_key_from_env()?;
    Ok(signing_key_to_address(&signing_key))
}

fn signing_key_from_env() -> Result<SigningKey> {
    let private_key = env_var("PRIVATE_KEY")?;
    let normalized = private_key.trim().trim_start_matches("0x");
    let decoded = hex::decode(normalized).with_context(|| "PRIVATE_KEY is not valid hex")?;
    SigningKey::from_slice(&decoded).with_context(|| "PRIVATE_KEY is not a valid secp256k1 private key")
}

fn signing_key_to_address(signing_key: &SigningKey) -> String {
    let verifying_key = signing_key.verifying_key();
    let public_key = verifying_key.to_encoded_point(false);
    let public_key_bytes = public_key.as_bytes();
    let hash = Keccak256::digest(&public_key_bytes[1..]);
    format!("0x{}", hex::encode(&hash[12..]))
}
