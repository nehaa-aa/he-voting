#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BITS=${BITS:-1024}
HEVOTE=${HEVOTE:-${CARGO_TARGET_DIR:-$ROOT/target}/release/hevote}

OPEN=false BITS=$BITS "$ROOT/scripts/deploy_open.sh"
"$HEVOTE" keygen --bits "$BITS" --members 5 --threshold 3 --out "$ROOT/work/demo/keys" --cached
echo
echo "Key shares: $ROOT/work/demo/keys/share_1.json ... share_5.json (member i uses share_i.json)"
echo "Now restart 'npm run dev' in web/ and open http://localhost:5173"