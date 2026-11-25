#![forbid(unsafe_code)]
use crypto_core::ballot::make_ballot;
use crypto_core::encoding::bigint_to_bytes;
use crypto_core::orproof::Context;
use crypto_core::paillier::PublicKey;
use num_bigint::BigUint;
use wasm_bindgen::prelude::*;

fn hex_bytes(s: &str) -> Result<Vec<u8>, String> {
    let raw = s.strip_prefix("0x").ok_or_else(|| "missing 0x prefix".to_string())?;
    hex::decode(raw).map_err(|e| e.to_string())
}

fn hex_exact<const N: usize>(s: &str) -> Result<[u8; N], String> {
    let b = hex_bytes(s)?;
    if b.len() != N {
        return Err(format!("expected {N} bytes, got {}", b.len()));
    }
    let mut a = [0u8; N];
    a.copy_from_slice(&b);
    Ok(a)
}

fn to_hex(v: &BigUint, width: usize) -> Result<String, String> {
    let b = bigint_to_bytes(v, width)
        .ok_or_else(|| "value does not fit its fixed width".to_string())?;
    Ok(format!("0x{}", hex::encode(b)))
}

/// Plain-Rust core so it can be unit-tested natively.
/// Never logs or returns r, and never puts the vote in an error message.
pub fn build_ballot(
    n_hex: &str,
    election_id_hex: &str,
    voter_hex: &str,
    vote: u8,
) -> Result<String, String> {
    if vote > 1 {
        return Err("vote must be 0 or 1".to_string());
    }
    let n_bytes = hex_bytes(n_hex)?;
    if !matches!(n_bytes.len(), 64 | 128 | 256) {
        return Err("n must be 64, 128 or 256 bytes".to_string());
    }
    if n_bytes[0] & 0x80 == 0 || n_bytes[n_bytes.len() - 1] & 1 == 0 {
        return Err("n must be odd and use its full bit length".to_string());
    }
    let pk = PublicKey::new(BigUint::from_bytes_be(&n_bytes));
    let ctx = Context {
        election_id: hex_exact::<32>(election_id_hex)?,
        voter: hex_exact::<20>(voter_hex)?,
    };

    let ballot = make_ballot(&pk, &ctx, vote);
    let k = pk.k_bytes();

    let voter = format!("0x{}", hex::encode(ctx.voter));
    let election_id = format!("0x{}", hex::encode(ctx.election_id));
    let c = to_hex(&ballot.c, 2 * k)?;
    let a0 = to_hex(&ballot.proof.a0, 2 * k)?;
    let a1 = to_hex(&ballot.proof.a1, 2 * k)?;
    let z0 = to_hex(&ballot.proof.z0, k)?;
    let z1 = to_hex(&ballot.proof.z1, k)?;
    let e0 = format!("0x{}", hex::encode(ballot.proof.e0.to_be_bytes()));
    let e1 = format!("0x{}", hex::encode(ballot.proof.e1.to_be_bytes()));

    let out = serde_json::json!({
        "voter": voter,
        "electionId": election_id,
        "c": c,
        "proof": { "a0": a0, "a1": a1, "z0": z0, "z1": z1, "e0": e0, "e1": e1 }
    });
    Ok(out.to_string())
}

/// Returns the ballot.json format (spec 6.1) as a JSON string.
#[wasm_bindgen]
pub fn encrypt_ballot(
    n_hex: &str,
    election_id_hex: &str,
    voter_hex: &str,
    vote: u8,
) -> Result<String, JsError> {
    build_ballot(n_hex, election_id_hex, voter_hex, vote).map_err(|e| JsError::new(&e))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crypto_core::orproof::{verify, Proof};

    const EID: &str = "0x0000000000000000000000000000000000000000000000000000000000000001";
    const VOTER: &str = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

    fn n512() -> String {
        let path = format!("{}/../fixtures/election_512.json", env!("CARGO_MANIFEST_DIR"));
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        v["n"].as_str().unwrap().to_string()
    }

    #[test]
    fn votes_other_than_0_or_1_are_rejected() {
        let n = n512();
        assert!(build_ballot(&n, EID, VOTER, 2).is_err());
        assert!(build_ballot(&n, EID, VOTER, 255).is_err());
    }

    #[test]
    fn bad_inputs_are_rejected() {
        let n = n512();
        assert!(build_ballot("0x1234", EID, VOTER, 1).is_err());
        assert!(build_ballot(&n, "0x01", VOTER, 1).is_err());
        assert!(build_ballot(&n, EID, "0x1234", 1).is_err());
        assert!(build_ballot(&n[2..], EID, VOTER, 1).is_err());
    }

    #[test]
    fn ballot_has_exactly_the_spec_fields_and_verifies_in_rust() {
        let n_hex = n512();
        for vote in [0u8, 1u8] {
            let s = build_ballot(&n_hex, EID, VOTER, vote).unwrap();
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            let mut keys: Vec<_> = v.as_object().unwrap().keys().cloned().collect();
            keys.sort();
            assert_eq!(keys, ["c", "electionId", "proof", "voter"]);

            let big = |f: &str| BigUint::from_bytes_be(&hex_bytes(v["proof"][f].as_str().unwrap()).unwrap());
            let e = |f: &str| u128::from_be_bytes(hex_exact::<16>(v["proof"][f].as_str().unwrap()).unwrap());
            let proof = Proof {
                a0: big("a0"), a1: big("a1"), z0: big("z0"), z1: big("z1"),
                e0: e("e0"), e1: e("e1"),
            };
            let c = BigUint::from_bytes_be(&hex_bytes(v["c"].as_str().unwrap()).unwrap());
            let pk = PublicKey::new(BigUint::from_bytes_be(&hex_bytes(&n_hex).unwrap()));
            let ctx = Context {
                election_id: hex_exact::<32>(EID).unwrap(),
                voter: hex_exact::<20>(VOTER).unwrap(),
            };
            assert!(verify(&pk, &ctx, &c, &proof));
        }
    }
}