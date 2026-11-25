#!/usr/bin/env bash
# Usage: scripts/read_tally.sh CONTRACT ID RPC [OUT=tally.json]
set -euo pipefail
[ $# -ge 3 ] || { echo "usage: $0 CONTRACT ID RPC [OUT]" >&2; exit 2; }
CONTRACT=$1; ID=$2; RPC=$3; OUT=${4:-tally.json}

TALLY=$(cast call "$CONTRACT" "getEncryptedTally(uint256)(bytes)" "$ID" --rpc-url "$RPC")
COUNT=$(cast call "$CONTRACT" "getElection(uint256)(address,uint8,bytes,uint256,uint8,uint8)" "$ID" --rpc-url "$RPC" | awk 'NR==4{print $1}')

mkdir -p "$(dirname "$OUT")"
jq -n --arg t "$TALLY" --argjson c "$COUNT" '{tally:$t, ballotCount:$c}' > "$OUT"
echo "wrote $OUT (ballotCount=$COUNT)"