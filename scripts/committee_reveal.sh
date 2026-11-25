#!/usr/bin/env bash
# Members 1, 2, 5 decrypt the closed tally, submit partials, and account 19 finalizes.
# Usage: BITS=1024 scripts/committee_reveal.sh      (BITS must match the deployed election)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
set -a; source web/.env.local; set +a
BITS=${BITS:-1024}
HEVOTE=${HEVOTE:-${CARGO_TARGET_DIR:-$ROOT/target}/release/hevote}
MNEMONIC="test test test test test test test test test test test junk"
W=$ROOT/work/reveal
SUBSET=(1 2 5)

rm -rf "$W"; mkdir -p "$W"
scripts/read_tally.sh "$VITE_CONTRACT_ADDRESS" "$VITE_ELECTION_ID" "$VITE_RPC_URL" "$W/tally.json"

"$HEVOTE" keygen --bits "$BITS" --members 5 --threshold 3 --out "$W/keys" --cached
for i in "${SUBSET[@]}"; do
  "$HEVOTE" partial-decrypt --pk "$W/keys/public.json" --share "$W/keys/share_$i.json" \
    --tally "$W/tally.json" --out "$W/partial_$i.json"
  export "M${i}_KEY=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index $((10 + i)))"
  scripts/submit_partial.sh "$VITE_CONTRACT_ADDRESS" "$VITE_ELECTION_ID" "$W/partial_$i.json" "M${i}_KEY" "$VITE_RPC_URL"
done

export FINALIZER_KEY=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 19)
export PK_FILE="$W/keys/public.json" HEVOTE
FILES=(); for i in "${SUBSET[@]}"; do FILES+=("$W/partial_$i.json"); done
scripts/finalize.sh "$VITE_CONTRACT_ADDRESS" "$VITE_ELECTION_ID" "${FILES[@]}" "$VITE_RPC_URL"
