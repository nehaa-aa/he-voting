use num_bigint::BigUint;
use num_traits::One;

use crate::error::Error;
use crate::orproof::{prove, verify, Context, Proof};
use crate::paillier::{add, encrypt_random, PublicKey};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ballot {
    pub c: BigUint,
    pub proof: Proof,
}

/// Encrypt a 0/1 vote with fresh OS randomness and prove it is 0 or 1.
/// The randomness r never leaves this function.
pub fn make_ballot(pk: &PublicKey, ctx: &Context, m: u8) -> Ballot {
    let (c, r) = encrypt_random(pk, m); // panics if m > 1
    let proof = prove(pk, ctx, m, &r, &c);
    Ballot { c, proof }
}

/// Verify every ballot (ballot i against ctx_for(i)), then multiply the
/// ciphertexts starting from 1. Any invalid ballot makes the whole call fail.
pub fn tally(
    pk: &PublicKey,
    ctx_for: &dyn Fn(usize) -> Context,
    ballots: &[Ballot],
) -> Result<BigUint, Error> {
    for (i, b) in ballots.iter().enumerate() {
        if !verify(pk, &ctx_for(i), &b.c, &b.proof) {
            return Err(Error::InvalidBallot(i));
        }
    }
    let mut t = BigUint::one();
    for b in ballots {
        t = add(pk, &t, &b.c);
    }
    Ok(t)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paillier::{
        decrypt_single, encrypt_unchecked, load_cached_key, random_r, DealerKey,
    };
    use crate::threshold::{combine, deal_shares, partial_decrypt, Partial};
    use num_traits::Zero;

    fn load(bits: usize) -> (PublicKey, DealerKey) {
        let path = format!("{}/../fixtures/dev_key_{}.json", env!("CARGO_MANIFEST_DIR"), bits);
        load_cached_key(path).expect("load cached key")
    }

    fn ctx(i: usize) -> Context {
        Context { election_id: [1u8; 32], voter: [(i as u8) + 1; 20] }
    }

    /// 6 yes + 4 no, ballot i bound to voter i.
    fn ten_ballots(pk: &PublicKey) -> Vec<Ballot> {
        let votes = [1u8, 0, 1, 1, 0, 1, 0, 1, 1, 0];
        votes.iter().enumerate().map(|(i, &v)| make_ballot(pk, &ctx(i), v)).collect()
    }

    fn decrypt_3_of_5(pk: &PublicKey, dk: &DealerKey, t: &BigUint, subset: [u32; 3]) -> BigUint {
        let shares = deal_shares(pk, dk, 5, 3);
        let partials: Vec<Partial> = subset
            .iter()
            .map(|i| partial_decrypt(pk, &shares[(*i - 1) as usize], t))
            .collect();
        combine(pk, &partials, 5, 3).unwrap()
    }

    #[test]
    fn ten_ballots_tally_and_decrypt_through_3_of_5() {
        let (pk, dk) = load(512);
        let ballots = ten_ballots(&pk);
        let t = tally(&pk, &|i| ctx(i), &ballots).unwrap();
        assert_eq!(decrypt_3_of_5(&pk, &dk, &t, [1, 2, 5]), BigUint::from(6u8));
        assert_eq!(decrypt_3_of_5(&pk, &dk, &t, [2, 3, 4]), BigUint::from(6u8));
    }

    #[test]
    fn ten_ballots_work_at_1024_bits() {
        let (pk, dk) = load(1024);
        let ballots = ten_ballots(&pk);
        let t = tally(&pk, &|i| ctx(i), &ballots).unwrap();
        assert_eq!(decrypt_3_of_5(&pk, &dk, &t, [1, 3, 5]), BigUint::from(6u8));
    }

    #[test]
    fn one_invalid_ballot_makes_tally_fail() {
        let (pk, _) = load(512);
        let mut ballots = ten_ballots(&pk);

        // ballot 4 encrypts 2; the cheater tries the "vote 1" witness
        let r = random_r(&pk);
        let c = encrypt_unchecked(&pk, &BigUint::from(2u8), &r);
        let proof = prove(&pk, &ctx(4), 1, &r, &c);
        ballots[4] = Ballot { c, proof };

        assert_eq!(tally(&pk, &|i| ctx(i), &ballots), Err(Error::InvalidBallot(4)));
    }

    #[test]
    fn ballot_bound_to_wrong_voter_is_rejected() {
        let (pk, _) = load(512);
        let mut ballots = ten_ballots(&pk);
        ballots.swap(0, 1); // each proof is now checked against the wrong voter
        assert!(matches!(
            tally(&pk, &|i| ctx(i), &ballots),
            Err(Error::InvalidBallot(_))
        ));
    }

    #[test]
    fn tampered_ciphertext_is_rejected() {
        let (pk, _) = load(512);
        let mut ballots = ten_ballots(&pk);
        ballots[7].c = &ballots[7].c ^ BigUint::one();
        assert_eq!(tally(&pk, &|i| ctx(i), &ballots), Err(Error::InvalidBallot(7)));
    }

    #[test]
    fn empty_tally_is_an_encryption_of_zero() {
        let (pk, dk) = load(512);
        let t = tally(&pk, &|i| ctx(i), &[]).unwrap();
        assert!(t.is_one());
        assert!(decrypt_single(&pk, &dk, &t).is_zero());
    }

    #[test]
    #[should_panic]
    fn make_ballot_rejects_vote_of_two() {
        let (pk, _) = load(512);
        let _ = make_ballot(&pk, &ctx(0), 2);
    }
}