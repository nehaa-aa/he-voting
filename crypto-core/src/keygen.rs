use num_bigint::BigUint;
use num_prime::RandPrime;
use rand08::{rngs::StdRng, SeedableRng};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use num_prime::nt_funcs::is_prime;
use num_prime::PrimalityTestConfig;

#[derive(Debug, Serialize, Deserialize)]
pub struct DevKey {
    pub key_bits: usize,
    pub p: String,
    pub q: String,
    pub n: String,
}

/// Generate safe primes p and q such that n = p * q has exactly
/// `modulus_bits` bits.
///
/// TEST KEYS ONLY: intended for development fixtures, not production use.
fn passes_40_random_rounds(candidate: &BigUint) -> bool {
    let mut config = PrimalityTestConfig::strict();
    config.sprp_random_trials = 40;

    is_prime(candidate, Some(config)).probably()
}
pub fn generate_safe_key(modulus_bits: usize) -> (BigUint, BigUint, BigUint) {
    assert!(modulus_bits >= 6, "modulus_bits must be at least 6");

    let prime_bits = modulus_bits / 2;
    let mut rng = StdRng::from_entropy();

    loop {
        let p: BigUint = rng.gen_safe_prime_exact(prime_bits);
        let q: BigUint = rng.gen_safe_prime_exact(prime_bits);

        if p == q {
            continue;
        }

        let n = &p * &q;

        if n.bits() == modulus_bits as u64 {
    let one = BigUint::from(1u8);
    let two = BigUint::from(2u8);

    let p_half = (&p - &one) / &two;
    let q_half = (&q - &one) / &two;

    if passes_40_random_rounds(&p)
        && passes_40_random_rounds(&q)
        && passes_40_random_rounds(&p_half)
        && passes_40_random_rounds(&q_half)
    {
        return (p, q, n);
    }
}
    }
}

fn to_hex(value: &BigUint) -> String {
    format!("0x{}", hex::encode(value.to_bytes_be()))
}

fn from_hex(value: &str) -> Result<BigUint, String> {
    let raw = value
        .strip_prefix("0x")
        .ok_or_else(|| "missing 0x prefix".to_string())?;
    let bytes = hex::decode(raw).map_err(|err| err.to_string())?;
    Ok(BigUint::from_bytes_be(&bytes))
}

/// Save a development key fixture. TEST KEYS ONLY: includes secret factors.
pub fn save_dev_key(
    path: impl AsRef<Path>,
    key_bits: usize,
    p: &BigUint,
    q: &BigUint,
    n: &BigUint,
) -> Result<(), String> {
    if p * q != *n || n.bits() != key_bits as u64 {
        return Err("key factors or modulus bit length are inconsistent".to_string());
    }

    let fixture = DevKey {
        key_bits,
        p: to_hex(p),
        q: to_hex(q),
        n: to_hex(n),
    };

    let json = serde_json::to_string_pretty(&fixture).map_err(|err| err.to_string())?;
    fs::write(path, format!("{json}\n"))
        .map_err(|err| err.to_string())
}

/// Load a development key fixture and verify n = p * q and its bit length.
pub fn load_dev_key(
    path: impl AsRef<Path>,
) -> Result<(usize, BigUint, BigUint, BigUint), String> {
    let contents = fs::read_to_string(path).map_err(|err| err.to_string())?;
    let fixture: DevKey =
        serde_json::from_str(&contents).map_err(|err| err.to_string())?;

    let p = from_hex(&fixture.p)?;
    let q = from_hex(&fixture.q)?;
    let n = from_hex(&fixture.n)?;

    if &p * &q != n {
        return Err("stored modulus does not equal p * q".to_string());
    }
    if n.bits() != fixture.key_bits as u64 {
        return Err("stored modulus has the wrong bit length".to_string());
    }

    Ok((fixture.key_bits, p, q, n))
}

#[cfg(test)]
mod tests {
    use super::*;
    use num_prime::nt_funcs::is_prime;

    #[test]
    fn generates_safe_primes_and_exact_modulus_bits() {
        let (p, q, n) = generate_safe_key(64);

        assert_ne!(p, q);
        assert_eq!(&p * &q, n);
        assert_eq!(n.bits(), 64);

        let two = BigUint::from(2u8);
        let one = BigUint::from(1u8);
        let p_half = (&p - &one) / &two;
        let q_half = (&q - &one) / &two;

        assert!(is_prime(&p, None).probably());
        assert!(is_prime(&q, None).probably());
        assert!(is_prime(&p_half, None).probably());
        assert!(is_prime(&q_half, None).probably());
    }

    #[test]
    fn save_and_load_dev_key_round_trip() {
        let (p, q, n) = generate_safe_key(64);
        let path = std::env::temp_dir().join("he_voting_dev_key_test.json");

        save_dev_key(&path, 64, &p, &q, &n).unwrap();
        let (bits, loaded_p, loaded_q, loaded_n) = load_dev_key(&path).unwrap();

        assert_eq!(bits, 64);
        assert_eq!(loaded_p, p);
        assert_eq!(loaded_q, q);
        assert_eq!(loaded_n, n);

        fs::remove_file(path).unwrap();
    }
}
