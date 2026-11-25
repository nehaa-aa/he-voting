# HE-Based Confidential DAO Voting (Phase 1, Part A: Rust crypto core)

Paillier-encrypted 0/1 votes, a non-interactive OR-proof that each ballot
encrypts 0 or 1, and 3-of-5 threshold decryption of the final tally only.

## Tool versions
- OS: Ubuntu 26.04.1 LTS (WSL2)
- rustc 1.99.1 (58cf8f9c3 2026-10-13)
- cargo 1.99.1 (5f94df478 2026-08-27)
- num-bigint 0.4.8, num-prime 0.7.0, sha3 0.12.0
- forge / anvil / cast:  1.8.6

## Layout
- `crypto-core/` Rust library: encoding, keygen, paillier, orproof, threshold, ballot
- `cli/` binary `hevote`
- `fixtures/` cached TEST keys, voters.json, election_512.json, election_1024.json

## Run
```bash
export CARGO_TARGET_DIR="$HOME/he-voting-target"   # optional, faster on WSL
cargo test --release
cargo build --release -p cli
H="$CARGO_TARGET_DIR/release/hevote"

# full election, asserts the result, writes fixtures/election_<bits>.json
$H demo --voters-file fixtures/voters.json --yes 6 --bits 512
$H demo --voters-file fixtures/voters.json --yes 6 --bits 1024

# re-verify a fixture from disk
$H verify-fixture --file fixtures/election_1024.json
```

### Manual election (CLI)
```bash
mkdir -p work/ballots
$H keygen --bits 512 --members 5 --threshold 3 --out work/keys --cached
$H vote --pk work/keys/public.json --election-id 1 --voter 0x7099...79C8 --choice 1 --out work/ballots/ballot_0.json
$H verify --pk work/keys/public.json --election-id 1 --ballot work/ballots/ballot_0.json
$H tally --pk work/keys/public.json --ballots work/ballots --out work/tally.json
$H partial-decrypt --pk work/keys/public.json --share work/keys/share_1.json --tally work/tally.json --out work/partial_1.json
$H combine --pk work/keys/public.json --partials work/partial_1.json work/partial_2.json work/partial_5.json --members 5 --threshold 3
```

## Measured results (from my own runs)
- 1024-bit safe-prime keygen: 4.08 s (release build)
- 512-bit safe-prime keygen: (fill in)
- demo, cached key: 512-bit 58.71 ms, 1024-bit 303.89 ms
- cargo test --release: 44 passed, 0 failed

## Assumptions
- Development on WSL2 Ubuntu. Native Windows Smart App Control blocked the
  Rust test binaries (Smart App Control was not disabled).
- Election id is 1 (32-byte big-endian). The contract must use ids starting at 1.
- Voters are Anvil accounts 1 to 10 (`anvil --accounts 11`); account 0 is the owner.
- `fixtures/dev_key_*.json` contain secret primes: TEST KEYS ONLY. `demo` uses
  them by default; `--fresh` generates a new key.
- Safe primes come from num-prime's generator, then p, q, (p-1)/2 and (q-1)/2
  are each re-checked with 40 random strong-probable-prime rounds.
- Demo committee is fixed at 5 members, threshold 3; members 1, 2, 5 decrypt
  (this subset has a negative Lagrange coefficient).
- `combine` uses exactly the first `threshold` partials and ignores extras.
- Invalid fixture ballots reuse valid voters' addresses. `wrong_voter_binding`
  is voter 0's ballot submitted as voter 1. `wrong_length` is `c` one byte short.
- `bigMathVectors`: each hex string carries its own byte width; exactSquare of a
  w-byte input outputs 2w bytes.
- The CLI `tally` additionally rejects duplicate voters and mixed election ids.
- OsRng from `rand` 0.8 (imported as `rand08`) draws every per-ballot `r`.

## Limitations
Not receipt-free; a quorum can decrypt single ballots (social rule); trusted
dealer; no proofs of correct partial decryption; 512/1024-bit keys are
prototype sizes. See spec section 7.

# Phase 1, Part B: Solidity contract (Foundry + Anvil)

## Run
```bash
cd contracts
forge test                                    # all contract tests (46)
forge test --gas-report
anvil --accounts 11 --hardfork cancun         # in a second terminal
BITS=1024 forge script script/RunElection.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd ..
H="$CARGO_TARGET_DIR/release/hevote"
$H keygen --bits 1024 --members 5 --threshold 3 --out work/chain/keys --cached
for i in 1 2 5; do $H partial-decrypt --pk work/chain/keys/public.json \
  --share work/chain/keys/share_$i.json --tally fixtures/onchain_tally.json \
  --out work/chain/partial_$i.json; done
$H combine --pk work/chain/keys/public.json --partials work/chain/partial_1.json \
  work/chain/partial_2.json work/chain/partial_5.json --members 5 --threshold 3
```
Use `BITS=512` and `--bits 512` for the 512-bit run.

## Results (details in contracts/GAS.md)
- forge: 46 tests pass at 512 and 1024 bits.
- castVote, average of 10: 426,431 gas (512-bit), 1,266,388 gas (1024-bit).
- The on-chain tally is byte-equal to expectedEncryptedTally; 3-of-5 decryption prints 6.

## Assumptions (Part B)
- Big-number arithmetic is my own BigMath on the modexp precompile. Zondax
  solidity-BigNumber does not compile with the optimizer on (see DECISIONS.md).
- evm_version is pinned to cancun; Anvil runs with --hardfork cancun.
- Election ids start at 1. A nonexistent id reverts WrongState (the spec has no
  "not found" error).
- createElection requires 1 <= threshold <= committeeSize, otherwise OutOfRange.
- Extra getter getModulus(id) (not in spec 5.3) exposes N and w for tests.
- castVote length and range checks live inside OrProofVerifier.verify, and run
  after the state and eligibility checks, matching the order in 5.5.
- Storage keeps only the tally and keccak256(c) per voter; the ciphertext is in the event.
- Forge warns about abi.encodePacked with several dynamic arguments. The inputs are
  rejected unless their lengths are exactly k or 2k bytes, so the encoding is
  unambiguous, and it is the exact encoding spec 2.3 requires. The require-revert-in-loop
  warnings are false positives (the reverts are in helper functions).
- Voters are Anvil accounts 1 to 10 and the owner is account 0. RunElection deploys a
  fresh contract on every run.
- The negative and replay tests run in forge's EVM, not against Anvil.
- Anvil is run with `--hardfork cancun`, matching `evm_version = "cancun"` in foundry.toml.
- The `getrandom` `js` feature is enabled in crypto-core under
  `cfg(target_arch = "wasm32")`, not only in the wasm crate, so that
  `cargo build -p crypto-core --target wasm32-unknown-unknown` (the Step 1 checkpoint)
  succeeds on its own. Native builds are unaffected.
- `keygen` is a default cargo feature; the WASM build uses `--no-default-features`.

# Phase 2
## Assumptions
- The crate is named he-wasm, so wasm-pack produces the package name he-wasm that web/package.json expects later.
- encrypt_ballot takes n as 64, 128 or 256 bytes of hex (the sizes the contract accepts), electionId as exactly 32 bytes and voter as exactly 20 bytes. Error messages never contain the vote.
- wasm-opt is disabled in the wasm-pack profile, because its download from GitHub is a common failure point. Remove that setting later if you want a smaller .wasm.
- validSubsets holds all 10 three-member subsets, not just the three example ones. The spec only requires that it include one with a negative lambda, and 10 gives the contract tests stronger coverage.
- mulSmall(x, s) returns a result of the same width as x and reverts if it doesn't fit. Each vector is {x, s, out} with s as a 32-byte hex value. The increment helper has no fixture list in 12.4, so Step 4 tests it with hand-made cases.
- badPartial is member 2's real partial with the lowest bit of its last byte flipped.
- The demo deals one set of shares per run, and the fixture's partials come from that dealing. Shares from a different keygen run can't be mixed with them.
- Errors. Wrong-length setCommittee → BadLength. Duplicate or zero-address members → OutOfRange. total > ballotCount → WrongTotal. Finalizing before close, or twice → WrongState.
- Check order in finalizeTally: state, committee set, indices (BadIndices), submitted (NotEnoughPartials), total range, then the equation.
- Committee size is capped at 20 (MAX_COMMITTEE), enforced in setCommittee. Beyond that, Δ = l! and the Lagrange products overflow, and I'd rather fail early than at finalize time.
- setCommittee can be called again while the state is Setup or Open, and it replaces the old committee.
- Extra public constant MAX_COMMITTEE (not in 12.3).

- The Results panel shows a locked state and a per-member signature list until `threshold` partials are
  submitted. The lock is enforced by the contract (finalizeTally needs `threshold` submitted partials);
  the UI only displays it.
## Step 5 and 6: on-chain reveal and committee scripts
Run (Anvil: `anvil --accounts 20 --hardfork cancun` in another terminal):
​```bash
export CARGO_TARGET_DIR="$HOME/he-voting-target"
chmod +x scripts/*.sh
(cd contracts && forge test)
BITS=512 scripts/e2e_anvil.sh
BITS=1024 scripts/e2e_anvil.sh
​```
Measured: forge test 76 passed, 0 failed (20 in RevealTest).

Assumptions:
- RunElection.s.sol now also calls setCommittee with fixtures/committee.json (Anvil accounts 11 to 15) and writes the contract address to fixtures/onchain_address.txt.
- e2e_anvil.sh runs on the Anvil that is already running, not a new one. RunElection deploys a fresh contract each run.
- Members 1, 2 and 5 submit partials (this subset has a negative Lagrange coefficient). Account 19 calls finalizeTally.
- Member and finalizer keys are derived from the public Anvil mnemonic inside the script and never written to disk.
- *.sh files use LF line endings (.gitattributes).

## Step 6 results
- `BITS=512 scripts/e2e_anvil.sh` and `BITS=1024 scripts/e2e_anvil.sh` both print
  `E2E PASSED: on-chain total = 6`. getResult shows finalized, total 6, partialCount 3.
- finalizeTally: 293,010 gas (512-bit), 445,775 gas (1024-bit) on Anvil (cancun).
- submitPartial: 183,879 to 200,967 gas (512-bit), 283,303 to 300,415 gas (1024-bit).
- forge test: 76 passed, 0 failed.

## Step 7: frontend skeleton
Run: `BITS=1024 scripts/deploy_open.sh` (deploys an open, empty election on Anvil and writes
web/.env.local), then `cd web && npm run dev` and open http://localhost:5173.
Assumptions:
- Added two view functions to HEVoting, `isEligible(id, who)` and `hasVoted(id, who)`, because the
  spec's interface has no way to read eligibility. Nothing else in the contract changed.
- `DeployOpen.s.sol` creates election 1 with no votes, so the browser and CLI can both vote later.
- web/.env.local is git-ignored. Restart the dev server after changing it.
- The `he-wasm` dependency is added in Step 8, after `wasm-pack build wasm --target web --release`.
- Sepolia is not supported in the frontend config; chain id 31337 (Anvil) only.

## Step 8: vote panel
Run: `wasm-pack build wasm --target web --release`, then in web/: `npm install --install-links ../wasm/pkg`,
`BITS=1024 scripts/deploy_open.sh`, `npm run dev`.
Assumptions:
- encrypt_ballot runs in a Web Worker (web/src/ballotWorker.ts) from the start, not only if the page freezes.
- The WASM package is installed with --install-links (a copy, not a symlink) because symlinks are unreliable
  on /mnt/d. Rerun the npm install after rebuilding the WASM.
- Encrypting and proving is one WASM call, so the progress shows "Encrypting and proving" as one stage,
  then Waiting for wallet, then Confirming.
- The vote panel stays visible for an eligible voter who already voted (spec 12.6 hides it), so a second
  attempt shows the readable AlreadyVoted message required by the Step 8 checkpoint.
- Measured browser time (encrypt and prove, my own runs): 1024-bit ___ ms, 512-bit ___ ms.

