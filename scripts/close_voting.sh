#!/usr/bin/env bash
# Owner (Anvil account 0) closes voting on the election in web/.env.local.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
set -a; source "$ROOT/web/.env.local"; set +a
MNEMONIC="test test test test test test test test test test test junk"
KEY=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 0)

R=$(cast send "$VITE_CONTRACT_ADDRESS" "closeVoting(uint256)" "$VITE_ELECTION_ID" \
  --private-key "$KEY" --rpc-url "$VITE_RPC_URL" --json)
echo "closeVoting: status=$(echo "$R" | jq -r .status) gasUsed=$(cast to-dec "$(echo "$R" | jq -r .gasUsed)")"