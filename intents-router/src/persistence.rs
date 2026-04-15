use anyhow::Context;
use serde::{Deserialize, Serialize};
use tokio::fs;

#[derive(Serialize, Deserialize)]
struct Cursor {
    last_processed_block: u64,
}

/// Read the last processed block from the cursor file.
/// Returns 0 if the file does not exist or cannot be parsed.
pub async fn read_last_block(path: &str) -> u64 {
    match fs::read_to_string(path).await {
        Ok(s) => serde_json::from_str::<Cursor>(&s)
            .map(|c| c.last_processed_block)
            .unwrap_or(0),
        Err(_) => 0,
    }
}

/// Atomically write the last processed block to the cursor file.
/// Uses write-to-tmp-then-rename to avoid corruption on crash.
pub async fn write_last_block(path: &str, block: u64) -> anyhow::Result<()> {
    let json = serde_json::to_string(&Cursor {
        last_processed_block: block,
    })?;
    let tmp = format!("{path}.tmp");
    fs::write(&tmp, json)
        .await
        .with_context(|| format!("write {tmp}"))?;
    fs::rename(&tmp, path)
        .await
        .with_context(|| format!("rename {tmp} → {path}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn round_trip() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("cursor.json").to_string_lossy().to_string();

        write_last_block(&path, 42).await.unwrap();
        assert_eq!(read_last_block(&path).await, 42);
    }

    #[tokio::test]
    async fn missing_file_returns_zero() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nonexistent.json").to_string_lossy().to_string();
        assert_eq!(read_last_block(&path).await, 0);
    }
}
