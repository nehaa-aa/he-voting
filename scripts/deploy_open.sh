#!/usr/bin/env bash
# Deploys an open, empty election on Anvil and writes web/.env.local for the frontend.
# Usage: BITS=1024 scripts/deploy_open.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BITS=${BITS:-1024}
RPC=${RPC:-http://127.0.0.1:8545}

(cd "$ROOT/contracts" && BITS=$BITS forge script script/DeployOpen.s.sol --rpc-url "$RPC" --broadcast >/dev/null)
ADDR=$(tr -d '[:space:]' < "$ROOT/fixtures/onchain_address.txt")

cat > "$ROOT/web/.env.local" <<ENV
VITE_CHAIN=anvil
VITE_RPC_URL=$RPC
VITE_CONTRACT_ADDRESS=$ADDR
VITE_ELECTION_ID=1
ENV
echo "Open election deployed at $ADDR. Wrote web/.env.local (restart npm run dev)."