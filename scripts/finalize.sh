#!/usr/bin/env bash
# Usage: scripts/finalize.sh CONTRACT ID PARTIAL_JSON... RPC   (RPC is the LAST argument)
# Env: FINALIZER_KEY (required), PK_FILE, MEMBERS (5), THRESHOLD (3), HEVOTE
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: $0 CONTRACT ID PARTIAL_JSON... RPC" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONTRACT=$1; ID=$2; shift 2
RPC=${!#}
PARTIALS=("${@:1:$#-1}")

HEVOTE=${HEVOTE:-${CARGO_TARGET_DIR:-$ROOT/target}/release/hevote}
PK_FILE=${PK_FILE:-$ROOT/work/e2e/keys/public.json}
MEMBERS=${MEMBERS:-5}; THRESHOLD=${THRESHOLD:-3}
[ -n "${FINALIZER_KEY:-}" ] || { echo "set FINALIZER_KEY" >&2; exit 1; }

OUT=$("$HEVOTE" combine --pk "$PK_FILE" --partials "${PARTIALS[@]}" --members "$MEMBERS" --threshold "$THRESHOLD" --json)
echo "combine: $OUT"
INDICES=$(echo "$OUT" | jq -c .indices)
TOTAL=$(echo "$OUT" | jq -r .total)

RECEIPT=$(cast send "$CONTRACT" "finalizeTally(uint256,uint8[],uint256)" "$ID" "$INDICES" "$TOTAL" \
  --private-key "$FINALIZER_KEY" --rpc-url "$RPC" --json)
STATUS=$(echo "$RECEIPT" | jq -r .status)
GAS=$(cast to-dec "$(echo "$RECEIPT" | jq -r .gasUsed)")
echo "finalizeTally: status=$STATUS gasUsed=$GAS tx=$(echo "$RECEIPT" | jq -r .transactionHash)"
[ "$STATUS" = "0x1" ] || [ "$STATUS" = "1" ] || exit 1
echo "finalized total = $TOTAL"