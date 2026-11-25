# Decisions

## D1. Big-number arithmetic (Step 2 spike)

**Question:** use the solidity-BigNumbers library, or write BigMath ourselves (spec 5.2)?

**Evidence (my own runs, forge 1.8.6, evm_version = cancun):**
- Raw modexp precompile (0x05) matches the Rust vectors: 8 vectors at 512-bit and
  8 at 1024-bit, all pass, including 2048-bit moduli.
- Gas, z^n mod N (the castVote shape): 45,027 (512-bit key), 351,154 (1024-bit key).
- Gas, y^e mod N with a 128-bit exponent: 12,326 (512), 44,703 (1024).
- Zondax/solidity-BigNumber v0.2.0 does NOT compile with solc 0.8.24 and the optimizer
  on: error 6553 (msize) at BigNumbers.sol lines 876, 937 and 1032. The spec requires
  the optimizer on, so the library was not measured.
- From reading its source: its functions are `public` (delegatecall and struct copying
  on every call), and it has no exact-square helper.

**Decision:** write BigMath ourselves on `bytes`, built on the modexp precompile, as the
5.2 fallback describes.

**Not chosen:** turning the Yul optimizer off (contradicts the spec, affects all gas
numbers) and patching the vendored library (extra unaudited code; its README says it
is unaudited).

**Open item:** Anvil's default hardfork is `latest`, which may price modexp differently.
foundry.toml pins evm_version = "cancun". Run Anvil with `--hardfork cancun` and report
the hardfork next to every gas number.