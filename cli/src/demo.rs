use super::*;
use crypto_core::orproof::prove;
use crypto_core::paillier::{encrypt_unchecked, random_r};
use rand::{rngs::OsRng, RngCore};
use std::time::Instant;

// ---------- fixture schema (spec 6.2) ----------

#[derive(Serialize, Deserialize)]
struct Committee {
    members: u32,
    threshold: u32,
}

#[derive(Serialize, Deserialize)]
struct ValidBallotJson {
    voter: String,
    vote: u8,
    c: String,
    proof: ProofJson,
}

#[derive(Serialize, Deserialize)]
struct InvalidBallotJson {
    voter: String,
    reason: String,
    c: String,
    proof: ProofJson,
}

#[derive(Serialize, Deserialize)]
struct ModexpVec {
    base: String,
    exp: String,
    #[serde(rename = "mod")]
    modulus: String,
    out: String,
}

#[derive(Serialize, Deserialize)]
struct MulmodVec {
    a: String,
    b: String,
    #[serde(rename = "mod")]
    modulus: String,
    out: String,
}

#[derive(Serialize, Deserialize)]
struct SquareVec {
    x: String,
    out: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BigMathVectors {
    modexp: Vec<ModexpVec>,
    mulmod: Vec<MulmodVec>,
    exact_square: Vec<SquareVec>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ElectionFixture {
    key_bits: usize,
    n: String,
    election_id: String,
    committee: Committee,
    valid_ballots: Vec<ValidBallotJson>,
    invalid_ballots: Vec<InvalidBallotJson>,
    expected_tally: u32,
    expected_encrypted_tally: String,
    big_math_vectors: BigMathVectors,
}

// ---------- helpers ----------

fn rand_bytes_value(nbytes: usize) -> BigUint {
    let mut buf = vec![0u8; nbytes];
    OsRng.fill_bytes(&mut buf);
    BigUint::from_bytes_be(&buf)
}

fn rand_below(upper: &BigUint) -> BigUint {
    let len = ((upper.bits() + 7) / 8) as usize + 16;
    rand_bytes_value(len) % upper
}

/// 0x-hex of any length (the width is carried by the string itself).
fn big_any(s: &str) -> Res<BigUint> {
    let raw = s.strip_prefix("0x").ok_or_else(|| "missing 0x prefix".to_string())?;
    Ok(BigUint::from_bytes_be(&hex::decode(raw).map_err(|e| e.to_string())?))
}

/// Would the contract-side checks accept this ballot? (parse + proof)
fn accepts(pk: &PublicKey, eid: &[u8; 32], voter: &str, c: &str, proof: &ProofJson) -> bool {
    let j = BallotJson {
        voter: voter.to_string(),
        election_id: hex_of(eid),
        c: c.to_string(),
        proof: proof.clone(),
    };
    match ballot_from_json(pk, &j) {
        Ok((ctx, b)) => verify(pk, &ctx, &b.c, &b.proof),
        Err(_) => false,
    }
}

fn invalid_entry(pk: &PublicKey, reason: &str, ctx: &Context, b: &Ballot) -> Res<InvalidBallotJson> {
    let j = ballot_to_json(pk, ctx, b)?;
    Ok(InvalidBallotJson { voter: j.voter, reason: reason.to_string(), c: j.c, proof: j.proof })
}

fn build_vectors(pk: &PublicKey) -> Res<BigMathVectors> {
    let k = pk.k_bytes();
    let nn = &pk.n2;
    let zero = BigUint::from(0u8);
    let one = BigUint::from(1u8);
    let nm1 = nn - &one;

    // modexp: base, exp, modulus each carry their own width
    let mut modexp = Vec::new();
    let mut me = |base: &BigUint, bw: usize, exp: &BigUint, ew: usize, m: &BigUint, mw: usize| -> Res<()> {
        let out = base.modpow(exp, m);
        modexp.push(ModexpVec {
            base: to_hex(base, bw)?,
            exp: to_hex(exp, ew)?,
            modulus: to_hex(m, mw)?,
            out: to_hex(&out, mw)?,
        });
        Ok(())
    };
    me(&random_r(pk), k, &pk.n, k, nn, 2 * k)?; // z^n mod N (the castVote shape)
    me(&rand_below(nn), 2 * k, &rand_bytes_value(16), 16, nn, 2 * k)?; // y^e mod N
    me(&zero, 2 * k, &rand_bytes_value(16), 16, nn, 2 * k)?; // 0^e
    me(&one, 2 * k, &pk.n, k, nn, 2 * k)?; // 1^n
    me(&nm1, 2 * k, &BigUint::from(3u8), 16, nn, 2 * k)?; // (N-1)^3 = N-1
    me(&nm1, 2 * k, &BigUint::from(4u8), 16, nn, 2 * k)?; // (N-1)^4 = 1
    me(&rand_below(nn), 2 * k, &zero, 16, nn, 2 * k)?; // x^0 = 1
    me(&random_r(pk), k, &rand_bytes_value(16), 16, &pk.n, k)?; // mod n (k bytes)

    // mulmod mod N, operands at 2k bytes
    let mut mulmod = Vec::new();
    let mut mm = |a: &BigUint, b: &BigUint| -> Res<()> {
        let out = (a * b) % nn;
        mulmod.push(MulmodVec {
            a: to_hex(a, 2 * k)?,
            b: to_hex(b, 2 * k)?,
            modulus: to_hex(nn, 2 * k)?,
            out: to_hex(&out, 2 * k)?,
        });
        Ok(())
    };
    mm(&zero, &rand_below(nn))?;
    mm(&one, &rand_below(nn))?;
    mm(&nm1, &nm1)?;
    mm(&nm1, &rand_below(nn))?;
    mm(&rand_below(nn), &rand_below(nn))?;
    mm(&rand_bytes_value(k), &rand_below(nn))?; // k-byte operand

    // exactSquare: w-byte input, 2w-byte output
    let mut exact_square = Vec::new();
    let mut sq = |x: &BigUint, w: usize| -> Res<()> {
        exact_square.push(SquareVec { x: to_hex(x, w)?, out: to_hex(&(x * x), 2 * w)? });
        Ok(())
    };
    let max_k = (BigUint::from(1u8) << (8 * k)) - &one;
    sq(&zero, k)?;
    sq(&one, k)?;
    sq(&max_k, k)?;
    sq(&rand_bytes_value(k), k)?;
    sq(&pk.n, k)?;
    sq(&rand_below(nn), 2 * k)?;
    sq(&nm1, 2 * k)?;

    Ok(BigMathVectors { modexp, mulmod, exact_square })
}

// ---------- demo ----------

pub fn run_demo(voters_file: &Path, yes: u32, bits: usize, fresh: bool, out_dir: &Path) -> Res<()> {
    let start = Instant::now();
    let voters: Vec<String> = read_json(voters_file)?;
    if voters.len() < 6 {
        return Err("need at least 6 voters (the invalid-ballot cases reuse them)".to_string());
    }
    if yes as usize > voters.len() {
        return Err("--yes is larger than the number of voters".to_string());
    }
    let len = voters.len();
    let (members, threshold) = (5u32, 3u32);

    let (pk, dk) = if fresh {
        generate_safe_key(bits)
    } else {
        load_cached_key(out_dir.join(format!("dev_key_{bits}.json")))?
    };
    if pk.key_bits != bits {
        return Err(format!("key has {} bits, expected {bits}", pk.key_bits));
    }
    let k = pk.k_bytes();
    println!("== {bits}-bit election, {} voters, {yes} yes / {} no ==", len, len as u32 - yes);

    let mut eid = [0u8; 32];
    eid[31] = 1; // election id 1 (contract ids start at 1)

    // 1. valid ballots
    let mut ctxs: Vec<Context> = Vec::new();
    let mut ballots: Vec<Ballot> = Vec::new();
    let mut valid_json: Vec<ValidBallotJson> = Vec::new();
    for (i, v) in voters.iter().enumerate() {
        let vote = if (i as u32) < yes { 1u8 } else { 0u8 };
        let ctx = Context { election_id: eid, voter: array_fixed::<20>(v)? };
        let b = make_ballot(&pk, &ctx, vote);
        let j = ballot_to_json(&pk, &ctx, &b)?;
        valid_json.push(ValidBallotJson { voter: j.voter, vote, c: j.c, proof: j.proof });
        ctxs.push(ctx);
        ballots.push(b);
    }

    // 2. invalid ballots
    let vctx = |i: usize| ctxs[i % len].clone();
    let mut invalid: Vec<InvalidBallotJson> = Vec::new();
    for (reason, value, who) in [("encrypts_2", 2u8, 0usize), ("encrypts_5", 5u8, 1usize)] {
        let ctx = vctx(who);
        let r = random_r(&pk);
        let c = encrypt_unchecked(&pk, &BigUint::from(value), &r);
        let proof = prove(&pk, &ctx, 1, &r, &c); // cheater uses the "vote 1" witness
        invalid.push(invalid_entry(&pk, reason, &ctx, &Ballot { c, proof })?);
    }
    let one = BigUint::from(1u8);
    let mut b = ballots[2].clone();
    b.proof.a0 = &b.proof.a0 ^ &one;
    invalid.push(invalid_entry(&pk, "tampered_a0", &vctx(2), &b)?);
    let mut b = ballots[3].clone();
    b.proof.z1 = &b.proof.z1 ^ &one;
    invalid.push(invalid_entry(&pk, "tampered_z1", &vctx(3), &b)?);
    let mut b = ballots[4].clone();
    b.proof.e0 ^= 1;
    invalid.push(invalid_entry(&pk, "tampered_e0", &vctx(4), &b)?);
    // ballot made for voter 0, submitted by voter 1
    invalid.push(invalid_entry(&pk, "wrong_voter_binding", &vctx(1), &ballots[0])?);
    // ciphertext one byte too short
    let mut e = invalid_entry(&pk, "wrong_length", &vctx(5), &ballots[5])?;
    e.c.truncate(e.c.len() - 2);
    invalid.push(e);

    // 3. every valid ballot is accepted, every invalid one rejected
    for (i, v) in valid_json.iter().enumerate() {
        if !accepts(&pk, &eid, &v.voter, &v.c, &v.proof) {
            return Err(format!("valid ballot {i} was rejected"));
        }
    }
    println!("accepted {} valid ballots", valid_json.len());
    for e in &invalid {
        if accepts(&pk, &eid, &e.voter, &e.c, &e.proof) {
            return Err(format!("invalid ballot '{}' was ACCEPTED", e.reason));
        }
        println!("rejected invalid ballot: {}", e.reason);
    }

    // 4. tally (verifies every ballot again, then multiplies)
    let t = tally(&pk, &|i: usize| ctxs[i].clone(), &ballots).map_err(|e| e.to_string())?;

    // 5. 3-of-5 decryption of the TALLY only (members 1, 2, 5: negative lambda)
    let shares = deal_shares(&pk, &dk, members, threshold);
    let partials: Vec<Partial> = [1u32, 2, 5]
        .iter()
        .map(|i| partial_decrypt(&pk, &shares[(*i - 1) as usize], &t))
        .collect();
    let total = combine(&pk, &partials, members, threshold).map_err(|e| e.to_string())?;
    if total != BigUint::from(yes) {
        return Err(format!("WRONG TOTAL: got {total}, expected {yes}"));
    }
    println!("3-of-5 decryption (members 1, 2, 5) of the tally: total = {total}");
    println!("no individual ballot was decrypted");

    // 6. write the fixture and re-verify it from disk
    let fx = ElectionFixture {
        key_bits: pk.key_bits,
        n: to_hex(&pk.n, k)?,
        election_id: hex_of(&eid),
        committee: Committee { members, threshold },
        valid_ballots: valid_json,
        invalid_ballots: invalid,
        expected_tally: yes,
        expected_encrypted_tally: to_hex(&t, 2 * k)?,
        big_math_vectors: build_vectors(&pk)?,
    };
    let path = out_dir.join(format!("election_{bits}.json"));
    write_json(&path, &fx)?;
    println!("wrote {}", path.display());
    verify_fixture(&path)?;
    println!("demo finished in {:.2?}", start.elapsed());
    Ok(())
}

// ---------- re-verification from the file ----------

pub fn verify_fixture(path: &Path) -> Res<()> {
    let fx: ElectionFixture = read_json(path)?;
    let k = fx.key_bits / 8;
    let pk = PublicKey::new(big_fixed(&fx.n, k)?);
    if pk.key_bits != fx.key_bits {
        return Err("n does not have exactly keyBits bits".to_string());
    }
    let eid = array_fixed::<32>(&fx.election_id)?;

    let mut ctxs = Vec::new();
    let mut ballots = Vec::new();
    let mut yes = 0u32;
    for (i, v) in fx.valid_ballots.iter().enumerate() {
        if !accepts(&pk, &eid, &v.voter, &v.c, &v.proof) {
            return Err(format!("valid ballot {i} failed verification"));
        }
        yes += v.vote as u32;
        let j = BallotJson {
            voter: v.voter.clone(),
            election_id: fx.election_id.clone(),
            c: v.c.clone(),
            proof: v.proof.clone(),
        };
        let (ctx, b) = ballot_from_json(&pk, &j)?;
        ctxs.push(ctx);
        ballots.push(b);
    }
    for (i, v) in fx.invalid_ballots.iter().enumerate() {
        if accepts(&pk, &eid, &v.voter, &v.c, &v.proof) {
            return Err(format!("invalid ballot {i} ({}) was accepted", v.reason));
        }
    }
    if yes != fx.expected_tally {
        return Err("expectedTally does not match the votes in validBallots".to_string());
    }
    let t = tally(&pk, &|i: usize| ctxs[i].clone(), &ballots).map_err(|e| e.to_string())?;
    if to_hex(&t, 2 * k)? != fx.expected_encrypted_tally {
        return Err("expectedEncryptedTally does not match the recomputed tally".to_string());
    }

    let vs = &fx.big_math_vectors;
    for (i, v) in vs.modexp.iter().enumerate() {
        let (b, e, m, o) = (big_any(&v.base)?, big_any(&v.exp)?, big_any(&v.modulus)?, big_any(&v.out)?);
        if b.modpow(&e, &m) != o || v.out.len() != v.modulus.len() {
            return Err(format!("modexp vector {i} is wrong"));
        }
    }
    for (i, v) in vs.mulmod.iter().enumerate() {
        let (a, b, m, o) = (big_any(&v.a)?, big_any(&v.b)?, big_any(&v.modulus)?, big_any(&v.out)?);
        if (a * b) % m != o || v.out.len() != v.modulus.len() {
            return Err(format!("mulmod vector {i} is wrong"));
        }
    }
    for (i, v) in vs.exact_square.iter().enumerate() {
        let (x, o) = (big_any(&v.x)?, big_any(&v.out)?);
        if &x * &x != o || v.out.len() != 2 * (v.x.len() - 2) + 2 {
            return Err(format!("exactSquare vector {i} is wrong"));
        }
    }

    println!(
        "fixture OK ({}): {} valid ballots accepted, {} invalid rejected, encrypted tally matches, {} modexp + {} mulmod + {} exactSquare vectors verified",
        path.display(),
        fx.valid_ballots.len(),
        fx.invalid_ballots.len(),
        vs.modexp.len(),
        vs.mulmod.len(),
        vs.exact_square.len()
    );
    Ok(())
}