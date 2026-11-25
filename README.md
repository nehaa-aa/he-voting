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

## Assumptions (where the spec is silent or I chose)
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

## Results (my own runs; details in contracts/GAS.md)
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