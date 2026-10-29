use num_bigint::BigUint;
use num_traits::{One, Zero};
use rand08::{rngs::OsRng, RngCore};

use crate::encoding::bigint_to_bytes;
use crate::hash::keccak256;
use crate::paillier::{mod_inverse, random_r, PublicKey};

#[derive(Clone, Debug)]
pub struct Context {
    pub election_id: [u8; 32],
    pub voter: [u8; 20],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Proof {
    pub a0: BigUint,
    pub a1: BigUint,
    pub z0: BigUint,
    pub z1: BigUint,
    pub e0: u128,
    pub e1: u128,
}

/// w = N - n + 1 = (1+n)^-1 mod N
fn w(pk: &PublicKey) -> BigUint {
    &pk.n2 - &pk.n + BigUint::one()
}

/// y0 = c, y1 = c * w mod N
fn ys(pk: &PublicKey, c: &BigUint) -> [BigUint; 2] {
    [c.clone(), (c * w(pk)) % &pk.n2]
}

fn random_u128() -> u128 {
    let mut b = [0u8; 16];
    OsRng.fill_bytes(&mut b);
    u128::from_be_bytes(b)
}

fn fixed(value: &BigUint, width: usize) -> Vec<u8> {
    bigint_to_bytes(value, width).expect("value does not fit its fixed width")
}

/// Exact Fiat-Shamir hash input (spec 2.3):
/// electionId(32) || voter(20) || n(k) || c(2k) || a0(2k) || a1(2k)
pub fn challenge_input(
    pk: &PublicKey,
    ctx: &Context,
    c: &BigUint,
    a0: &BigUint,
    a1: &BigUint,
) -> Vec<u8> {
    let k = pk.k_bytes();
    let mut buf = Vec::with_capacity(32 + 20 + k + 6 * k);
    buf.extend_from_slice(&ctx.election_id);
    buf.extend_from_slice(&ctx.voter);
    buf.extend_from_slice(&fixed(&pk.n, k));
    buf.extend_from_slice(&fixed(c, 2 * k));
    buf.extend_from_slice(&fixed(a0, 2 * k));
    buf.extend_from_slice(&fixed(a1, 2 * k));
    buf
}

/// Low 128 bits of keccak256(input) = last 16 bytes, big-endian.
pub fn challenge(
    pk: &PublicKey,
    ctx: &Context,
    c: &BigUint,
    a0: &BigUint,
    a1: &BigUint,
) -> u128 {
    let digest = keccak256(&challenge_input(pk, ctx, c, a0, a1));
    let mut low = [0u8; 16];
    low.copy_from_slice(&digest[16..32]);
    u128::from_be_bytes(low)
}

/// Prover for "c encrypts 0 or 1". `m` is the real vote, `r` the
/// randomness used in `c`. Never log `r`.
pub fn prove(pk: &PublicKey, ctx: &Context, m: u8, r: &BigUint, c: &BigUint) -> Proof {
    assert!(m <= 1, "vote must be 0 or 1");
    let t = m as usize; // real branch
    let f = 1 - t; // simulated branch
    let y = ys(pk, c);

    // Real branch commitment
    let s = random_r(pk);
    let a_t = s.modpow(&pk.n, &pk.n2);

    // Simulated branch
    let e_f = random_u128();
    let z_f = random_r(pk);
    let yf_inv = mod_inverse(&y[f], &pk.n2).expect("y_f must be invertible mod N");
    let a_f = (z_f.modpow(&pk.n, &pk.n2) * yf_inv.modpow(&BigUint::from(e_f), &pk.n2))
        % &pk.n2;

    let mut a = [BigUint::zero(), BigUint::zero()];
    a[t] = a_t;
    a[f] = a_f;

    let h = challenge(pk, ctx, c, &a[0], &a[1]);
    let e_t = h.wrapping_sub(e_f); // (H - e_f) mod 2^128
    let z_t = (&s * r.modpow(&BigUint::from(e_t), &pk.n)) % &pk.n;

    let mut e = [0u128; 2];
    let mut z = [BigUint::zero(), BigUint::zero()];
    e[t] = e_t;
    e[f] = e_f;
    z[t] = z_t;
    z[f] = z_f;

    let [a0, a1] = a;
    let [z0, z1] = z;
    Proof { a0, a1, z0, z1, e0: e[0], e1: e[1] }
}

fn in_range(x: &BigUint, upper: &BigUint) -> bool {
    !x.is_zero() && x < upper
}

pub fn verify(pk: &PublicKey, ctx: &Context, c: &BigUint, proof: &Proof) -> bool {
    // Range checks first, so the fixed-width encodings below always fit.
    if !in_range(c, &pk.n2)
        || !in_range(&proof.a0, &pk.n2)
        || !in_range(&proof.a1, &pk.n2)
        || !in_range(&proof.z0, &pk.n)
        || !in_range(&proof.z1, &pk.n)
    {
        return false;
    }

    let h = challenge(pk, ctx, c, &proof.a0, &proof.a1);
    if proof.e0.wrapping_add(proof.e1) != h {
        return false;
    }

    let y = ys(pk, c);
    let a = [&proof.a0, &proof.a1];
    let z = [&proof.z0, &proof.z1];
    let e = [proof.e0, proof.e1];

    for i in 0..2 {
        let lhs = z[i].modpow(&pk.n, &pk.n2);
        let rhs = (a[i] * y[i].modpow(&BigUint::from(e[i]), &pk.n2)) % &pk.n2;
        if lhs != rhs {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paillier::{encrypt, encrypt_random, encrypt_unchecked, load_cached_key, DealerKey};

    fn load(bits: usize) -> (PublicKey, DealerKey) {
        let path = format!("{}/../fixtures/dev_key_{}.json", env!("CARGO_MANIFEST_DIR"), bits);
        load_cached_key(path).expect("load cached key")
    }

    fn ctx() -> Context {
        Context { election_id: [7u8; 32], voter: [9u8; 20] }
    }

    fn random_below(upper: &BigUint, bytes: usize) -> BigUint {
        loop {
            let mut buf = vec![0u8; bytes];
            OsRng.fill_bytes(&mut buf);
            let x = BigUint::from_bytes_be(&buf) % upper;
            if !x.is_zero() {
                return x;
            }
        }
    }

    #[test]
    fn challenge_input_has_exact_length() {
        for bits in [512usize, 1024] {
            let (pk, _) = load(bits);
            let k = pk.k_bytes();
            let (c, _) = encrypt_random(&pk, 1);
            let buf = challenge_input(&pk, &ctx(), &c, &BigUint::one(), &BigUint::one());
            assert_eq!(buf.len(), 32 + 20 + k + 2 * k + 2 * k + 2 * k);
            assert_eq!(&buf[..32], &[7u8; 32]);
            assert_eq!(&buf[32..52], &[9u8; 20]);
        }
    }

    #[test]
    fn valid_proofs_verify_for_0_and_1() {
        for bits in [512usize, 1024] {
            let (pk, _) = load(bits);
            for m in [0u8, 1u8] {
                for _ in 0..5 {
                    let (c, r) = encrypt_random(&pk, m);
                    let proof = prove(&pk, &ctx(), m, &r, &c);
                    assert!(verify(&pk, &ctx(), &c, &proof), "bits={bits} m={m}");
                }
            }
        }
    }

    #[test]
    fn flipping_one_bit_of_any_field_fails() {
        let (pk, _) = load(512);
        for m in [0u8, 1u8] {
            let (c, r) = encrypt_random(&pk, m);
            let good = prove(&pk, &ctx(), m, &r, &c);
            assert!(verify(&pk, &ctx(), &c, &good));

            let one = BigUint::one();
            let mut bad = good.clone();
            bad.a0 = &good.a0 ^ &one;
            assert!(!verify(&pk, &ctx(), &c, &bad), "a0");

            let mut bad = good.clone();
            bad.a1 = &good.a1 ^ &one;
            assert!(!verify(&pk, &ctx(), &c, &bad), "a1");

            let mut bad = good.clone();
            bad.z0 = &good.z0 ^ &one;
            assert!(!verify(&pk, &ctx(), &c, &bad), "z0");

            let mut bad = good.clone();
            bad.z1 = &good.z1 ^ &one;
            assert!(!verify(&pk, &ctx(), &c, &bad), "z1");

            let mut bad = good.clone();
            bad.e0 ^= 1;
            assert!(!verify(&pk, &ctx(), &c, &bad), "e0");

            let mut bad = good.clone();
            bad.e1 ^= 1;
            assert!(!verify(&pk, &ctx(), &c, &bad), "e1");
        }
    }

    #[test]
    fn wrong_voter_or_election_id_fails() {
        let (pk, _) = load(512);
        let (c, r) = encrypt_random(&pk, 1);
        let proof = prove(&pk, &ctx(), 1, &r, &c);
        assert!(verify(&pk, &ctx(), &c, &proof));

        let mut other_voter = ctx();
        other_voter.voter[0] ^= 1;
        assert!(!verify(&pk, &other_voter, &c, &proof));

        let mut other_election = ctx();
        other_election.election_id[31] ^= 1;
        assert!(!verify(&pk, &other_election, &c, &proof));
    }

    #[test]
    fn proof_does_not_transfer_to_another_ciphertext() {
        let (pk, _) = load(512);
        let (c1, r1) = encrypt_random(&pk, 1);
        let (c2, _) = encrypt_random(&pk, 1);
        let proof = prove(&pk, &ctx(), 1, &r1, &c1);
        assert!(!verify(&pk, &ctx(), &c2, &proof));
    }

    #[test]
    fn ciphertexts_of_2_5_1000_never_verify() {
        for bits in [512usize, 1024] {
            let (pk, _) = load(bits);
            for v in [2u32, 5, 1000] {
                for _ in 0..3 {
                    let r = random_r(&pk);
                    let c = encrypt_unchecked(&pk, &BigUint::from(v), &r);
                    // cheating prover tries both witnesses
                    for m in [0u8, 1u8] {
                        let proof = prove(&pk, &ctx(), m, &r, &c);
                        assert!(!verify(&pk, &ctx(), &c, &proof), "v={v} m={m} bits={bits}");
                    }
                }
            }
        }
    }

    #[test]
    fn random_ciphertext_never_verifies() {
        let (pk, _) = load(512);
        for _ in 0..5 {
            let c = random_below(&pk.n2, 2 * pk.k_bytes() + 8);
            let r = random_r(&pk);
            for m in [0u8, 1u8] {
                let proof = prove(&pk, &ctx(), m, &r, &c);
                assert!(!verify(&pk, &ctx(), &c, &proof));
            }
        }
    }

    #[test]
    fn out_of_range_values_are_rejected() {
        let (pk, _) = load(512);
        let (c, r) = encrypt_random(&pk, 0);
        let good = prove(&pk, &ctx(), 0, &r, &c);

        let mut bad = good.clone();
        bad.z0 = BigUint::zero();
        assert!(!verify(&pk, &ctx(), &c, &bad));

        let mut bad = good.clone();
        bad.z1 = pk.n.clone(); // z must be < n
        assert!(!verify(&pk, &ctx(), &c, &bad));

        let mut bad = good.clone();
        bad.a0 = pk.n2.clone(); // a must be < N
        assert!(!verify(&pk, &ctx(), &c, &bad));

        assert!(!verify(&pk, &ctx(), &BigUint::zero(), &good));
        assert!(!verify(&pk, &ctx(), &pk.n2, &good));
    }

    #[test]
    fn encrypt_with_checked_api_also_proves() {
        let (pk, _) = load(512);
        let r = random_r(&pk);
        let c = encrypt(&pk, 1, &r);
        let proof = prove(&pk, &ctx(), 1, &r, &c);
        assert!(verify(&pk, &ctx(), &c, &proof));
    }
}