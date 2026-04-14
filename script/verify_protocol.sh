#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_FILE="${1:-$ROOT_DIR/broadcast/DeployProtocol.s.sol/4441/runFullWithOracle-latest.json}"
CHAIN_ID="${CHAIN_ID:-4441}"
VERIFIER_URL="${VERIFIER_URL:-https://liteforge.explorer.caldera.xyz/api/}"

if [[ ! -f "$RUN_FILE" ]]; then
  echo "Run file not found: $RUN_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed" >&2
  exit 1
fi

verify() {
  local address="$1"
  local contract_path="$2"

  if [[ -z "$address" || "$address" == "null" ]]; then
    echo "Skipping $contract_path because address is missing" >&2
    return
  fi

  echo "Verifying $contract_path at $address"
  forge verify-contract \
    "$address" \
    "$contract_path" \
    --chain-id "$CHAIN_ID" \
    --verifier blockscout \
    --verifier-url "$VERIFIER_URL" \
    --watch
}

extract_address() {
  local contract_name="$1"
  jq -r --arg name "$contract_name" '
    .transactions[]
    | select(.contractName == $name and .contractAddress != null)
    | .contractAddress
    ' "$RUN_FILE" | head -n 1
}

VAULT_IMPL="$(extract_address "AyniVault")"
REGISTRY="$(extract_address "AyniVaultRegistry")"
FACTORY="$(extract_address "AyniVaultFactory")"
PROTOCOL="$(extract_address "AyniProtocol")"
SETTLER="$(extract_address "AyniDestinationSettler")"
WZKLTC="$(extract_address "WrappedZkLTC")"
POOL="$(extract_address "AyniSolverPool")"

verify "$VAULT_IMPL" "$ROOT_DIR/src/AyniVault.sol:AyniVault"
verify "$REGISTRY" "$ROOT_DIR/src/AyniVaultRegistry.sol:AyniVaultRegistry"
verify "$FACTORY" "$ROOT_DIR/src/AyniVaultFactory.sol:AyniVaultFactory"
verify "$PROTOCOL" "$ROOT_DIR/src/AyniProtocol.sol:AyniProtocol"
verify "$SETTLER" "$ROOT_DIR/src/AyniDestinationSettler.sol:AyniDestinationSettler"
verify "$WZKLTC" "$ROOT_DIR/src/WrappedZkLTC.sol:WrappedZkLTC"
verify "$POOL" "$ROOT_DIR/src/AyniSolverPool.sol:AyniSolverPool"

echo
echo "Verification complete."
echo "Note: the market vault created by the factory is a clone of the AyniVault implementation,"
echo "so you typically verify the implementation rather than the clone instance."
