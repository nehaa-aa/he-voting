use num_bigint::BigUint;
use num_traits::{One, Zero};
use rand08::{rngs::OsRng, RngCore};

use crate::error::Error;
use crate::paillier::{mod_inverse, DealerKey, PublicKey};

/// Secret share. Deliberately not Debug.
#[derive(Clone)]
pub struct KeyShare {
    pub index: u32,
    pub value: BigUint,
    pub members: u32,
    pub threshold: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Partial {
    pub index: u32,
    pub value: BigUint,
}

fn delta_big(members: u32) -> BigUint {
    (1..=members).fold(BigUint::one(), |acc, i| acc * BigUint::from(i))
}

fn random_below(upper: &BigUint) -> BigUint {
    // 128 extra bits make the modular bias negligible.
    let len = ((upper.bits() + 7) / 8) as usize + 16;
    let mut buf = vec![0u8; len];
    OsRng.fill_bytes(&mut buf);
    BigUint::from_bytes_be(&buf) % upper
}

/// Shamir-share d over Z_(n*m): random polynomial of degree t-1, f(0) = d,
/// member i gets f(i) mod (n*m).
pub fn deal_shares(
    pk: &PublicKey,
    dk: &DealerKey,
    members: u32,
    threshold: u32,
) -> Vec<KeyShare> {
    assert!(threshold >= 1 && threshold <= members, "need 1 <= t <= l");
    let modulus = &pk.n * &dk.m;

    let mut coeffs = vec![&dk.d % &modulus];
    for _ in 1..threshold {
        coeffs.push(random_below(&modulus));
    }

    (1..=members)
        .map(|i| {
            let x = BigUint::from(i);
            // Horner evaluation mod n*m
            let mut acc = BigUint::zero();
            for coeff in coeffs.iter().rev() {
                acc = (acc * &x + coeff) % &modulus;
            }
            KeyShare { index: i, value: acc, members, threshold }
        })
        .collect()
}

/// c_i = c^(2 * Delta * s_i) mod n^2
pub fn partial_decrypt(pk: &PublicKey, share: &KeyShare, c: &BigUint) -> Partial {
    assert!(!c.is_zero() && c < &pk.n2, "ciphertext out of range");
    let exp = BigUint::from(2u8) * delta_big(share.members) * &share.value;
    Partial { index: share.index, value: c.modpow(&exp, &pk.n2) }
}

/// lambda_i^S = Delta * prod_{j in S, j != i} j / (j - i), exact integers
/// (may be negative). Asserts the division is exact.
pub fn lagrange_coefficients(indices: &[u32], members: u32) -> Vec<i128> {
    let delta: i128 = (1..=members as i128).product();
    indices
        .iter()
        .map(|&i| {
            let i = i as i128;
            let mut num = delta;
            let mut den = 1i128;
            for &j in indices {
                let j = j as i128;
                if j == i {
                    continue;
                }
                num *= j;
                den *= j - i;
            }
            assert_eq!(num % den, 0, "Lagrange coefficient must be an exact integer");
            num / den
        })
        .collect()
}

/// Combine partial decryptions into the plaintext. Rejects fewer than
/// `threshold` partials and uses exactly the first `threshold` of them.
pub fn combine(
    pk: &PublicKey,
    partials: &[Partial],
    members: u32,
    threshold: u32,
) -> Result<BigUint, Error> {
    let t = threshold as usize;
    if partials.len() < t {
        return Err(Error::NotEnoughPartials { have: partials.len(), need: t });
    }
    let used = &partials[..t];

    let mut indices: Vec<u32> = Vec::with_capacity(t);
    for p in used {
        if p.index < 1 || p.index > members {
            return Err(Error::BadIndex(p.index));
        }
        if indices.contains(&p.index) {
            return Err(Error::DuplicateIndex(p.index));
        }
        if p.value.is_zero() || p.value >= pk.n2 {
            return Err(Error::BadPartial);
        }
        indices.push(p.index);
    }

    let lambdas = lagrange_coefficients(&indices, members);

    let mut acc = BigUint::one();
    for (p, lam) in used.iter().zip(lambdas.iter()) {
        let exp = BigUint::from(lam.unsigned_abs()) * BigUint::from(2u8);
        let base = if *lam < 0 {
            mod_inverse(&p.value, &pk.n2).ok_or(Error::BadPartial)?
        } else {
            p.value.clone()
        };
        acc = (acc * base.modpow(&exp, &pk.n2)) % &pk.n2;
    }

    // c' must be 1 + k*n, otherwise the partials do not belong together.
    if acc.is_zero() || !((&acc - BigUint::one()) % &pk.n).is_zero() {
        return Err(Error::NotDecryptable);
    }
    let l = (&acc - BigUint::one()) / &pk.n;

    let delta = delta_big(members);
    let four_delta_sq = BigUint::from(4u8) * &delta * &delta;
    let inv = mod_inverse(&(four_delta_sq % &pk.n), &pk.n).ok_or(Error::NotDecryptable)?;
    Ok((l * inv) % &pk.n)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paillier::{add, encrypt_random, generate_safe_key, load_cached_key};

    fn load(bits: usize) -> (PublicKey, DealerKey) {
        let path = format!("{}/../fixtures/dev_key_{}.json", env!("CARGO_MANIFEST_DIR"), bits);
        load_cached_key(path).expect("load cached key")
    }

    /// Encrypted sum of `ones` yes-votes and `zeros` no-votes.
    fn make_tally(pk: &PublicKey, ones: u32, zeros: u32) -> BigUint {
        let mut t = BigUint::one();
        for _ in 0..ones {
            let (c, _) = encrypt_random(pk, 1);
            t = add(pk, &t, &c);
        }
        for _ in 0..zeros {
            let (c, _) = encrypt_random(pk, 0);
            t = add(pk, &t, &c);
        }
        t
    }

    fn subsets(members: u32, t: usize) -> Vec<Vec<u32>> {
        fn rec(start: u32, members: u32, t: usize, cur: &mut Vec<u32>, out: &mut Vec<Vec<u32>>) {
            if cur.len() == t {
                out.push(cur.clone());
                return;
            }
            for i in start..=members {
                cur.push(i);
                rec(i + 1, members, t, cur, out);
                cur.pop();
            }
        }
        let mut out = Vec::new();
        rec(1, members, t, &mut Vec::new(), &mut out);
        out
    }

    fn pick(all: &[Partial], idx: &[u32]) -> Vec<Partial> {
        idx.iter()
            .map(|i| all.iter().find(|p| p.index == *i).unwrap().clone())
            .collect()
    }

    #[test]
    fn lagrange_coefficients_sum_to_delta_and_can_be_negative() {
        // {1,2,5} of 5: lambdas are 300, -200, 20 (Delta = 120)
        assert_eq!(lagrange_coefficients(&[1, 2, 5], 5), vec![300, -200, 20]);
        for s in subsets(5, 3) {
            let sum: i128 = lagrange_coefficients(&s, 5).iter().sum();
            assert_eq!(sum, 120, "subset {s:?}");
        }
    }

    #[test]
    fn three_members_threshold_two_all_pairs_recover_plaintext() {
        let (pk, dk) = load(512);
        let shares = deal_shares(&pk, &dk, 3, 2);
        let c = make_tally(&pk, 2, 1); // plaintext 2
        let partials: Vec<Partial> = shares.iter().map(|s| partial_decrypt(&pk, s, &c)).collect();
        for s in subsets(3, 2) {
            let got = combine(&pk, &pick(&partials, &s), 3, 2).unwrap();
            assert_eq!(got, BigUint::from(2u8), "subset {s:?}");
        }
    }

    #[test]
    fn five_members_threshold_three_all_ten_subsets_agree() {
        let (pk, dk) = load(512);
        let shares = deal_shares(&pk, &dk, 5, 3);
        let c = make_tally(&pk, 6, 4); // plaintext 6
        let partials: Vec<Partial> = shares.iter().map(|s| partial_decrypt(&pk, s, &c)).collect();

        let all = subsets(5, 3);
        assert_eq!(all.len(), 10);
        let mut saw_negative = false;
        for s in &all {
            if lagrange_coefficients(s, 5).iter().any(|l| *l < 0) {
                saw_negative = true;
            }
            let got = combine(&pk, &pick(&partials, s), 5, 3).unwrap();
            assert_eq!(got, BigUint::from(6u8), "subset {s:?}");
        }
        assert!(saw_negative, "at least one subset must have a negative lambda");
        // the spec's named example
        let got = combine(&pk, &pick(&partials, &[1, 2, 5]), 5, 3).unwrap();
        assert_eq!(got, BigUint::from(6u8));
    }

    #[test]
    fn two_partials_are_rejected() {
        let (pk, dk) = load(512);
        let shares = deal_shares(&pk, &dk, 5, 3);
        let c = make_tally(&pk, 1, 0);
        let partials: Vec<Partial> = shares.iter().map(|s| partial_decrypt(&pk, s, &c)).collect();
        let res = combine(&pk, &pick(&partials, &[1, 2]), 5, 3);
        assert_eq!(res, Err(Error::NotEnoughPartials { have: 2, need: 3 }));
        assert_eq!(
            combine(&pk, &[], 5, 3),
            Err(Error::NotEnoughPartials { have: 0, need: 3 })
        );
    }

    #[test]
    fn duplicate_and_out_of_range_indices_are_rejected() {
        let (pk, dk) = load(512);
        let shares = deal_shares(&pk, &dk, 5, 3);
        let c = make_tally(&pk, 1, 0);
        let partials: Vec<Partial> = shares.iter().map(|s| partial_decrypt(&pk, s, &c)).collect();

        let dup = vec![partials[0].clone(), partials[1].clone(), partials[0].clone()];
        assert_eq!(combine(&pk, &dup, 5, 3), Err(Error::DuplicateIndex(1)));

        let mut bad = pick(&partials, &[1, 2, 3]);
        bad[2].index = 6;
        assert_eq!(combine(&pk, &bad, 5, 3), Err(Error::BadIndex(6)));
        bad[2].index = 0;
        assert_eq!(combine(&pk, &bad, 5, 3), Err(Error::BadIndex(0)));
    }

    #[test]
    fn combine_uses_exactly_the_first_t_partials() {
        let (pk, dk) = load(512);
        let shares = deal_shares(&pk, &dk, 5, 3);
        let c = make_tally(&pk, 3, 2);
        let partials: Vec<Partial> = shares.iter().map(|s| partial_decrypt(&pk, s, &c)).collect();
        // 4 partials supplied; only the first 3 are used
        let got = combine(&pk, &pick(&partials, &[2, 4, 5, 1]), 5, 3).unwrap();
        assert_eq!(got, BigUint::from(3u8));
    }

    #[test]
    fn partial_from_a_different_key_gives_a_wrong_value() {
        let (pk_a, dk_a) = load(512);
        let (_pk_b, dk_b) = generate_safe_key(512);
        let shares_a = deal_shares(&pk_a, &dk_a, 5, 3);
        // key B's shares, but evaluated against key A's modulus
        let pk_b_as_a = pk_a.clone();
        let shares_b = deal_shares(&pk_b_as_a, &dk_b, 5, 3);

        let c = make_tally(&pk_a, 6, 4);
        let mut partials: Vec<Partial> =
            shares_a.iter().map(|s| partial_decrypt(&pk_a, s, &c)).collect();

        // sanity: honest partials work
        assert_eq!(
            combine(&pk_a, &pick(&partials, &[1, 2, 3]), 5, 3),
            Ok(BigUint::from(6u8))
        );

        // replace member 3's partial with one from the other key
        partials[2] = partial_decrypt(&pk_a, &shares_b[2], &c);
        let res = combine(&pk_a, &pick(&partials, &[1, 2, 3]), 5, 3);
        assert_ne!(res, Ok(BigUint::from(6u8)));
    }

    #[test]
    fn works_at_1024_bits() {
        let (pk, dk) = load(1024);
        let shares = deal_shares(&pk, &dk, 5, 3);
        let c = make_tally(&pk, 3, 2);
        let partials: Vec<Partial> = shares.iter().map(|s| partial_decrypt(&pk, s, &c)).collect();
        for s in [vec![1, 2, 5], vec![2, 4, 5], vec![1, 3, 4]] {
            let got = combine(&pk, &pick(&partials, &s), 5, 3).unwrap();
            assert_eq!(got, BigUint::from(3u8), "subset {s:?}");
        }
    }
}