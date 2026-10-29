# HE-Based Confidential DAO Voting (Phase 1, Part A: Rust crypto core)

Paillier-encrypted 0/1 votes, a non-interactive OR-proof that each ballot
encrypts 0 or 1, and 3-of-5 threshold decryption of the final tally only.

## Tool versions
(paste the output of the version commands here)

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