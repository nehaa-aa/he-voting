# Gas measurements (my own runs)

Environment: forge 1.8.6, solc 0.8.24, optimizer on (200 runs), evm_version = cancun.
Deployed bytecode size: 8,388 bytes (limit 24,576).
These are forge-test numbers. Real-transaction gas from Anvil is in the last table.

## castVote (forge --gas-report, 10 calls each)
| Key size | Min | Average | Median | Max |
|---|---|---|---|---|
| 512-bit  | 419,263   | 426,431   | 419,736   | 487,820   |
| 1024-bit | 1,251,071 | 1,266,388 | 1,252,882 | 1,391,163 |

Measured inside the test around the call, the first ballot costs 490,703 (512) and
1,395,118 (1024), and the average of 10 is 429,964 and 1,270,993. These are a few
thousand higher than the report because the measurement wraps the call.
The first ballot is the most expensive, likely because it turns the zero words of the
initial tally (just the value 1) into nonzero words. The single-transaction cap
is about 16.7M, and 1024-bit castVote is about 7.5% of that.

## Other functions (forge --gas-report)
| Function | 512-bit | 1024-bit |
|---|---|---|
| createElection | 648,027 | 883,726 |
| openVoting | 27,043 | 27,043 |
| closeVoting | ___ | ___ |

## OrProofVerifier.verify, alone (10 valid ballots, called through a test harness)
| Key size | Average | Range |
|---|---|---|
| 512-bit  | 248,023   | 247,650 to 248,326 |
| 1024-bit | 1,005,746 | 1,004,123 to 1,006,824 |

## Primitives in isolation (BigMath on Rust vectors)
| Operation | 512-bit key | 1024-bit key |
|---|---|---|
| modexp z^n mod N (n-bit exponent, 2k-byte modulus) | 45,029 | 351,156 |
| modexp y^e mod N (128-bit exponent) | 12,328 | 44,705 |
| mulmodN, average of 6 vectors | 36,262 | 60,296 |
| exactSquare, k-byte input | 2,835 | 3,704 |
| exactSquare, 2k-byte input | 3,704 | 6,161 |

## Where the verify gas goes (arithmetic on the measured numbers above)
verify = 2 x (z^n modexp) + 2 x (y^e modexp) + 3 x mulmodN + other.
| | 512-bit | 1024-bit |
|---|---|---|
| 2 x z^n | 90,058 | 702,312 |
| 2 x y^e | 24,656 | 89,410 |
| 3 x mulmodN | about 108,800 | about 180,900 |
| Sum | about 223,500 | about 972,600 |
| Measured verify | 248,023 | 1,005,746 |
| Other (range checks, keccak, copies, harness) | about 24,500 | about 33,100 |

At 1024 bits the two z^n exponentiations are about 70% of the verification cost.
castVote minus verify is about 178,400 (512) and 260,600 (1024): the tally multiply
(one mulmodN), storage writes and the event.

## Real transactions on Anvil (Step 9)
Anvil started with `anvil --accounts 11 --hardfork cancun`. Gas used per receipt,
from `broadcast/RunElection.s.sol/31337/run-latest.json`.

| Transaction | 512-bit | 1024-bit |
|---|---|---|
| deploy (same bytecode) | 1,860,821 | 1,860,821 |
| createElection | 648,027 | 883,726 |
| openVoting | 27,043 | 27,043 |
| castVote, first ballot | 487,820 | 1,391,163 |
| castVote, average of 10 | 426,431 | 1,266,388 |
| castVote, minimum | 419,263 | 1,251,071 |
| closeVoting | 40,972 | 50,712 |
| all 14 transactions together | 6,841,179 | 15,486,189 |

All 10 ballots were accepted on-chain at both key sizes. The final tally equals
`expectedEncryptedTally`, and 3-of-5 decryption of it with the CLI (members 1, 2, 5)
prints 6 at both sizes. The 1024-bit total is spread over 14 separate transactions,
so no single transaction is anywhere near the 16.7M per-transaction cap (largest
single transaction: 1,860,821 for the deployment).

These equal the forge `--gas-report` values (min, average and max of castVote at
both key sizes), and one transaction was checked directly on Anvil with
`cast receipt` (the first 512-bit castVote: 487,820).

## Phase 2: reveal, real transactions on Anvil (Step 6)
Anvil: `anvil --accounts 20 --hardfork cancun`. Gas used per receipt from `scripts/e2e_anvil.sh`
(members 1, 2, 5 submit; account 19 finalizes). Committee size 5, threshold 3.

| Transaction | 512-bit | 1024-bit |
|---|---|---|
| deploy (now includes the reveal code) | 2,877,641 | 2,877,641 |
| createElection | 648,087 | 883,786 |
| setCommittee (5 members) | 297,570 | 297,570 |
| openVoting | 27,065 | 27,065 |
| castVote, first ballot | 488,701 | 1,390,024 |
| castVote, average of 10 | 426,541 | 1,266,634 |
| castVote, range of the other 9 | 419,423 to 419,909 | 1,252,327 to 1,253,562 |
| closeVoting | 40,972 | 50,712 |
| submitPartial, first member | 200,967 | 300,415 |
| submitPartial, later members | 183,879 and 183,891 | 283,303 and 283,303 |
| finalizeTally (members 1, 2, 5) | 293,010 | 445,775 |
| setup and voting (deploy to close, 15 txs) | 8,156,749 | 16,803,120 |

finalizeTally in forge tests, all 10 subsets: 294,005 to 294,914 (512-bit) and
446,680 to 450,308 (1024-bit). These match the Anvil values to within about 1k gas.

Notes:
- The first submitPartial costs about 17k to 18k (512-bit) or 17k (1024-bit) more than the
  later ones, because the partialCount storage slot goes from zero to nonzero.
- The deploy cost rose from 1,860,821 (Phase 1) to 2,877,641 because of the reveal functions.
- The largest single transaction is the deployment at 2,877,641, far below the 16.7M cap.
  The 1024-bit voting total is spread over 15 transactions.
- These supersede the Step 9 "real transactions" table, which predates setCommittee.