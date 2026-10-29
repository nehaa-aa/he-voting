use num_bigint::{BigInt, BigUint};
use num_integer::Integer;
use num_traits::{One, Zero};
use rand08::{rngs::OsRng, RngCore};
use std::path::Path;

use crate::keygen;

#[derive(Clone, Debug)]
pub struct PublicKey {
    pub n: BigUint,
    pub n2: BigUint,
    pub key_bits: usize,
}

impl PublicKey {
    pub fn new(n: BigUint) -> Self {
        let n2 = &n * &n;
        let key_bits = n.bits() as usize;
        PublicKey { n, n2, key_bits }
    }

    /// k = keyBits / 8 bytes
    pub fn k_bytes(&self) -> usize {
        self.key_bits / 8
    }
}

/// Secret material. Deliberately NOT Debug, Clone or Serialize, so it
/// cannot be logged or written out by accident.
#[allow(dead_code)]
pub struct DealerKey {
    pub(crate) p: BigUint,
    pub(crate) q: BigUint,
    pub(crate) p_half: BigUint, // p'
    pub(crate) q_half: BigUint, // q'
    pub(crate) lambda: BigUint, // lcm(p-1, q-1)
    pub(crate) m: BigUint,      // p' * q'
    pub(crate) d: BigUint,      // d = 0 mod m, d = 1 mod n
}

impl DealerKey {
    pub fn from_primes(p: &BigUint, q: &BigUint) -> Self {
        let one = BigUint::one();
        let two = BigUint::from(2u8);
        let n = p * q;
        let p_half = (p - &one) / &two;
        let q_half = (q - &one) / &two;
        let lambda = (p - &one).lcm(&(q - &one));
        let m = &p_half * &q_half;
        // CRT: d = m * (m^-1 mod n)  =>  d mod m = 0, d mod n = 1
        let m_inv = mod_inverse(&(&m % &n), &n).expect("m must be invertible mod n");
        let d = &m * &m_inv;
        DealerKey {
            p: p.clone(),
            q: q.clone(),
            p_half,
            q_half,
            lambda,
            m,
            d,
        }
    }
}

/// Modular inverse of a mod modulus, or None if gcd != 1.
pub fn mod_inverse(a: &BigUint, modulus: &BigUint) -> Option<BigUint> {
    let a = BigInt::from(a.clone());
    let m = BigInt::from(modulus.clone());
    let eg = a.extended_gcd(&m);
    if !eg.gcd.is_one() {
        return None;
    }
    eg.x.mod_floor(&m).to_biguint()
}

/// Uniform r in [1, n) with gcd(r, n) = 1, from the OS CSPRNG.
fn random_unit(n: &BigUint, k_bytes: usize) -> BigUint {
    let mut buf = vec![0u8; k_bytes];
    loop {
        OsRng.fill_bytes(&mut buf);
        let r = BigUint::from_bytes_be(&buf);
        if !r.is_zero() && &r < n && r.gcd(n).is_one() {
            return r;
        }
    }
}

/// Fresh uniform r for a ballot. Never log or reuse it.
pub fn random_r(pk: &PublicKey) -> BigUint {
    random_unit(&pk.n, pk.k_bytes())
}

/// Spec 4.3: generate a key from safe primes.
pub fn generate_safe_key(bits: usize) -> (PublicKey, DealerKey) {
    let (p, q, n) = keygen::generate_safe_key(bits);
    (PublicKey::new(n), DealerKey::from_primes(&p, &q))
}

/// Load a cached TEST key (fixtures/dev_key_*.json).
pub fn load_cached_key(path: impl AsRef<Path>) -> Result<(PublicKey, DealerKey), String> {
    let (bits, p, q, n) = keygen::load_dev_key(path)?;
    let pk = PublicKey::new(n);
    if pk.key_bits != bits {
        return Err("key_bits does not match n".to_string());
    }
    Ok((pk, DealerKey::from_primes(&p, &q)))
}

/// Enc(m; r) = (1 + m*n) * r^n mod n^2, for m in {0,1}.
pub fn encrypt(pk: &PublicKey, m: u8, r: &BigUint) -> BigUint {
    assert!(m <= 1, "vote must be 0 or 1");
    encrypt_unchecked(pk, &BigUint::from(m), r)
}

/// Tests only: any plaintext, used to build invalid ballots and big sums.
pub fn encrypt_unchecked(pk: &PublicKey, m: &BigUint, r: &BigUint) -> BigUint {
    assert!(!r.is_zero() && r < &pk.n, "r must be in [1, n)");
    assert!(r.gcd(&pk.n).is_one(), "r must be coprime to n");
    let gm = (BigUint::one() + m * &pk.n) % &pk.n2;
    let rn = r.modpow(&pk.n, &pk.n2);
    (gm * rn) % &pk.n2
}

/// Encrypt with a fresh OS-random r. Returns (c, r).
pub fn encrypt_random(pk: &PublicKey, m: u8) -> (BigUint, BigUint) {
    let r = random_r(pk);
    let c = encrypt(pk, m, &r);
    (c, r)
}

/// Single-key decryption. Test oracle only.
pub fn decrypt_single(pk: &PublicKey, dk: &DealerKey, c: &BigUint) -> BigUint {
    assert!(c < &pk.n2, "ciphertext out of range");
    let x = c.modpow(&dk.lambda, &pk.n2);
    let l = (x - BigUint::one()) / &pk.n; // L(x) = (x-1)/n
    let mu = mod_inverse(&(&dk.lambda % &pk.n), &pk.n).expect("lambda invertible mod n");
    (l * mu) % &pk.n
}

/// Homomorphic addition: c1 * c2 mod n^2.
pub fn add(pk: &PublicKey, c1: &BigUint, c2: &BigUint) -> BigUint {
    (c1 * c2) % &pk.n2
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/../fixtures/{}", env!("CARGO_MANIFEST_DIR"), name)
    }

    fn load(name: &str) -> (PublicKey, DealerKey) {
        load_cached_key(fixture(name)).expect("load cached key")
    }

    #[test]
    fn n_has_exact_bit_length() {
        let (pk, _) = load("dev_key_512.json");
        assert_eq!(pk.n.bits(), 512);
        assert_eq!(pk.key_bits, 512);
        let (pk, _) = load("dev_key_1024.json");
        assert_eq!(pk.n.bits(), 1024);
        assert_eq!(pk.key_bits, 1024);
    }

    #[test]
    fn dealer_key_relations_hold() {
        let (pk, dk) = load("dev_key_512.json");
        assert!((&dk.d % &dk.m).is_zero());
        assert!((&dk.d % &pk.n).is_one());
        assert_eq!(dk.lambda, BigUint::from(2u8) * &dk.m);
        assert_eq!(&dk.p * &dk.q, pk.n);
    }

    #[test]
    fn encrypt_decrypt_zero_and_one_many_r() {
        let (pk, dk) = load("dev_key_512.json");
        for _ in 0..50 {
            for m in [0u8, 1u8] {
                let (c, _r) = encrypt_random(&pk, m);
                assert_eq!(decrypt_single(&pk, &dk, &c), BigUint::from(m));
            }
        }
    }

    #[test]
    fn same_vote_encrypts_differently() {
        let (pk, _) = load("dev_key_512.json");
        let (c1, r1) = encrypt_random(&pk, 1);
        let (c2, r2) = encrypt_random(&pk, 1);
        assert_ne!(r1, r2);
        assert_ne!(c1, c2);
    }

    #[test]
    fn sum_of_50_random_votes_decrypts_to_count() {
        let (pk, dk) = load("dev_key_512.json");
        let mut tally = BigUint::one(); // encryption of 0 with r = 1
        let mut expected = 0u32;
        for _ in 0..50 {
            let vote = (OsRng.next_u32() & 1) as u8;
            expected += vote as u32;
            let (c, _) = encrypt_random(&pk, vote);
            tally = add(&pk, &tally, &c);
        }
        assert_eq!(decrypt_single(&pk, &dk, &tally), BigUint::from(expected));
    }

    #[test]
    fn unchecked_encrypts_values_above_one() {
        let (pk, dk) = load("dev_key_512.json");
        for v in [2u32, 5, 1000] {
            let r = random_r(&pk);
            let c = encrypt_unchecked(&pk, &BigUint::from(v), &r);
            assert_eq!(decrypt_single(&pk, &dk, &c), BigUint::from(v));
        }
    }

    #[test]
    #[should_panic]
    fn encrypt_rejects_vote_of_two() {
        let (pk, _) = load("dev_key_512.json");
        let r = random_r(&pk);
        let _ = encrypt(&pk, 2, &r);
    }

    #[test]
    fn works_at_1024_bits() {
        let (pk, dk) = load("dev_key_1024.json");
        let (c0, _) = encrypt_random(&pk, 0);
        let (c1, _) = encrypt_random(&pk, 1);
        let (c1b, _) = encrypt_random(&pk, 1);
        assert_eq!(decrypt_single(&pk, &dk, &c0), BigUint::zero());
        let sum = add(&pk, &add(&pk, &c0, &c1), &c1b);
        assert_eq!(decrypt_single(&pk, &dk, &sum), BigUint::from(2u8));
    }

    #[test]
    fn fresh_small_key_round_trip() {
        let (pk, dk) = generate_safe_key(128);
        assert_eq!(pk.n.bits(), 128);
        let (c, _) = encrypt_random(&pk, 1);
        assert_eq!(decrypt_single(&pk, &dk, &c), BigUint::one());
    }
}