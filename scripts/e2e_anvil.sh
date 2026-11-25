#!/usr/bin/env bash
# Needs: anvil --accounts 20 --hardfork cancun running.  Run: BITS=1024 scripts/e2e_anvil.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

BITS=${BITS:-1024}
RPC=${RPC:-http://127.0.0.1:8545}
HEVOTE=${HEVOTE:-${CARGO_TARGET_DIR:-$ROOT/target}/release/hevote}
MNEMONIC="test test test test test test test test test test test junk"
FIX=$ROOT/fixtures/election_$BITS.json
W=$ROOT/work/e2e
SUBSET=(1 2 5)

fail() { echo "E2E FAILED: $*" >&2; exit 1; }
for t in cast jq forge; do command -v $t >/dev/null || fail "$t not installed"; done
[ -x "$HEVOTE" ] || fail "hevote not found at $HEVOTE (set HEVOTE or CARGO_TARGET_DIR)"
[ -f "$FIX" ] || fail "$FIX missing"
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || fail "no chain at $RPC"

echo "== 1. deploy, create, set committee, open, vote, close ($BITS-bit) =="
(cd contracts && BITS=$BITS forge script script/RunElection.s.sol --rpc-url "$RPC" --broadcast >/dev/null)
CONTRACT=$(tr -d '[:space:]' < fixtures/onchain_address.txt)
ID=$(cast to-dec "$(jq -r .electionId "$FIX")")
EXPECTED=$(jq -r .expectedTally "$FIX")
echo "contract=$CONTRACT electionId=$ID expectedTally=$EXPECTED"

echo "== 2. read the encrypted tally =="
rm -rf "$W"; mkdir -p "$W"
scripts/read_tally.sh "$CONTRACT" "$ID" "$RPC" "$W/tally.json"

echo "== 3. members decrypt their share of the tally =="
"$HEVOTE" keygen --bits "$BITS" --members 5 --threshold 3 --out "$W/keys" --cached
for i in "${SUBSET[@]}"; do
  "$HEVOTE" partial-decrypt --pk "$W/keys/public.json" --share "$W/keys/share_$i.json" \
    --tally "$W/tally.json" --out "$W/partial_$i.json"
done

echo "== 4. members submit partials on-chain (accounts 11-15 = members 1-5) =="
for i in "${SUBSET[@]}"; do
  export "M${i}_KEY=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index $((10 + i)))"
  scripts/submit_partial.sh "$CONTRACT" "$ID" "$W/partial_$i.json" "M${i}_KEY" "$RPC"
done

echo "== 5. anyone finalizes =="
export FINALIZER_KEY=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index 19)
export PK_FILE="$W/keys/public.json" HEVOTE
PARTIAL_FILES=(); for i in "${SUBSET[@]}"; do PARTIAL_FILES+=("$W/partial_$i.json"); done
scripts/finalize.sh "$CONTRACT" "$ID" "${PARTIAL_FILES[@]}" "$RPC"

echo "== 6. check getResult =="
mapfile -t R < <(cast call "$CONTRACT" "getResult(uint256)(bool,uint256,uint8)" "$ID" --rpc-url "$RPC" | awk '{print $1}')
echo "getResult: finalized=${R[0]} total=${R[1]} partialCount=${R[2]}"
[ "${R[0]}" = "true" ]      || fail "not finalized"
[ "${R[1]}" = "$EXPECTED" ] || fail "total ${R[1]} != expected $EXPECTED"
[ "${R[2]}" = "3" ]         || fail "partialCount ${R[2]} != 3"
echo "E2E PASSED: on-chain total = $EXPECTED"