#!/usr/bin/env bash
# Usage: scripts/submit_partial.sh CONTRACT ID PARTIAL_JSON KEY_ENV RPC
set -euo pipefail
[ $# -eq 5 ] || { echo "usage: $0 CONTRACT ID PARTIAL_JSON KEY_ENV RPC" >&2; exit 2; }
CONTRACT=$1; ID=$2; PARTIAL=$3; KEY_ENV=$4; RPC=$5

KEY=${!KEY_ENV:-}
[ -n "$KEY" ] || { echo "environment variable $KEY_ENV is empty" >&2; exit 1; }
VALUE=$(jq -r .value "$PARTIAL")
INDEX=$(jq -r .index "$PARTIAL")

RECEIPT=$(cast send "$CONTRACT" "submitPartial(uint256,bytes)" "$ID" "$VALUE" \
  --private-key "$KEY" --rpc-url "$RPC" --json)
STATUS=$(echo "$RECEIPT" | jq -r .status)
GAS=$(cast to-dec "$(echo "$RECEIPT" | jq -r .gasUsed)")
echo "member $INDEX submitPartial: status=$STATUS gasUsed=$GAS tx=$(echo "$RECEIPT" | jq -r .transactionHash)"
[ "$STATUS" = "0x1" ] || [ "$STATUS" = "1" ] || exit 1