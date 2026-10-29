mod demo;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use crypto_core::ballot::{make_ballot, tally, Ballot};
use crypto_core::encoding::bigint_to_bytes;
use crypto_core::orproof::{verify, Context, Proof};
use crypto_core::paillier::{generate_safe_key, load_cached_key, PublicKey};
use crypto_core::threshold::{combine, deal_shares, partial_decrypt, KeyShare, Partial};
use num_bigint::BigUint;
use serde::{Deserialize, Serialize};

type Res<T> = Result<T, String>;

// ---------- JSON formats (spec section 6.1) ----------

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PublicJson {
    key_bits: usize,
    n: String,
}

#[derive(Serialize, Deserialize)]
struct ShareJson {
    index: u32,
    members: u32,
    threshold: u32,
    n: String,
    value: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct ProofJson {
    a0: String,
    a1: String,
    z0: String,
    z1: String,
    e0: String,
    e1: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BallotJson {
    voter: String,
    election_id: String,
    c: String,
    proof: ProofJson,
}

#[derive(Serialize, Deserialize)]
struct PartialJson {
    index: u32,
    value: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TallyJson {
    tally: String,
    ballot_count: usize,
}

// ---------- helpers ----------

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Res<T> {
    let s = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&s).map_err(|e| format!("{}: {e}", path.display()))
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> Res<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        }
    }
    let s = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    fs::write(path, format!("{s}\n")).map_err(|e| format!("{}: {e}", path.display()))
}

/// 0x-prefixed hex that must decode to exactly `width` bytes.
fn fixed_bytes(s: &str, width: usize) -> Res<Vec<u8>> {
    let raw = s.strip_prefix("0x").ok_or_else(|| "missing 0x prefix".to_string())?;
    let b = hex::decode(raw).map_err(|e| e.to_string())?;
    if b.len() != width {
        return Err(format!("expected {width} bytes, got {}", b.len()));
    }
    Ok(b)
}

fn big_fixed(s: &str, width: usize) -> Res<BigUint> {
    Ok(BigUint::from_bytes_be(&fixed_bytes(s, width)?))
}

fn array_fixed<const N: usize>(s: &str) -> Res<[u8; N]> {
    let b = fixed_bytes(s, N)?;
    let mut a = [0u8; N];
    a.copy_from_slice(&b);
    Ok(a)
}

fn u128_fixed(s: &str) -> Res<u128> {
    Ok(u128::from_be_bytes(array_fixed::<16>(s)?))
}

fn to_hex(v: &BigUint, width: usize) -> Res<String> {
    let b = bigint_to_bytes(v, width).ok_or_else(|| "value does not fit its fixed width".to_string())?;
    Ok(format!("0x{}", hex::encode(b)))
}

fn hex_of(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

/// Election id: decimal ("1") or 0x-hex, as a 32-byte big-endian value.
fn parse_election_id(s: &str) -> Res<[u8; 32]> {
    let v = if let Some(h) = s.strip_prefix("0x") {
        let h = if h.len() % 2 == 1 { format!("0{h}") } else { h.to_string() };
        BigUint::from_bytes_be(&hex::decode(h).map_err(|e| e.to_string())?)
    } else {
        s.parse::<BigUint>().map_err(|e| format!("bad election id: {e}"))?
    };
    let b = bigint_to_bytes(&v, 32).ok_or_else(|| "election id does not fit 32 bytes".to_string())?;
    let mut out = [0u8; 32];
    out.copy_from_slice(&b);
    Ok(out)
}

fn load_pk(path: &Path) -> Res<PublicKey> {
    let j: PublicJson = read_json(path)?;
    if j.key_bits == 0 || j.key_bits % 8 != 0 {
        return Err("keyBits must be a positive multiple of 8".to_string());
    }
    let n = big_fixed(&j.n, j.key_bits / 8)?;
    let pk = PublicKey::new(n);
    if pk.key_bits != j.key_bits {
        return Err("n does not have exactly keyBits bits".to_string());
    }
    Ok(pk)
}

fn ballot_to_json(pk: &PublicKey, ctx: &Context, b: &Ballot) -> Res<BallotJson> {
    let k = pk.k_bytes();
    Ok(BallotJson {
        voter: hex_of(&ctx.voter),
        election_id: hex_of(&ctx.election_id),
        c: to_hex(&b.c, 2 * k)?,
        proof: ProofJson {
            a0: to_hex(&b.proof.a0, 2 * k)?,
            a1: to_hex(&b.proof.a1, 2 * k)?,
            z0: to_hex(&b.proof.z0, k)?,
            z1: to_hex(&b.proof.z1, k)?,
            e0: hex_of(&b.proof.e0.to_be_bytes()),
            e1: hex_of(&b.proof.e1.to_be_bytes()),
        },
    })
}

fn ballot_from_json(pk: &PublicKey, j: &BallotJson) -> Res<(Context, Ballot)> {
    let k = pk.k_bytes();
    let ctx = Context {
        election_id: array_fixed::<32>(&j.election_id)?,
        voter: array_fixed::<20>(&j.voter)?,
    };
    let ballot = Ballot {
        c: big_fixed(&j.c, 2 * k)?,
        proof: Proof {
            a0: big_fixed(&j.proof.a0, 2 * k)?,
            a1: big_fixed(&j.proof.a1, 2 * k)?,
            z0: big_fixed(&j.proof.z0, k)?,
            z1: big_fixed(&j.proof.z1, k)?,
            e0: u128_fixed(&j.proof.e0)?,
            e1: u128_fixed(&j.proof.e1)?,
        },
    };
    Ok((ctx, ballot))
}

// ---------- commands ----------

#[derive(Parser)]
#[command(name = "hevote", about = "HE-based confidential DAO voting tool")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Generate a key and Shamir-split it among the committee.
    Keygen {
        #[arg(long)]
        bits: usize,
        #[arg(long, default_value_t = 5)]
        members: u32,
        #[arg(long, default_value_t = 3)]
        threshold: u32,
        #[arg(long)]
        out: PathBuf,
        /// Reuse fixtures/dev_key_<bits>.json instead of generating a key.
        #[arg(long)]
        cached: bool,
    },
    /// Encrypt a 0/1 vote and prove it, writing one ballot.
    Vote {
        #[arg(long)]
        pk: PathBuf,
        #[arg(long = "election-id")]
        election_id: String,
        #[arg(long)]
        voter: String,
        #[arg(long, value_parser = clap::value_parser!(u8).range(0..=1))]
        choice: u8,
        #[arg(long)]
        out: PathBuf,
    },
    /// Check one ballot. Exit code 0 = valid, 1 = invalid.
    Verify {
        #[arg(long)]
        pk: PathBuf,
        #[arg(long = "election-id")]
        election_id: String,
        #[arg(long)]
        ballot: PathBuf,
    },
    /// Verify every ballot in a directory and multiply them.
    Tally {
        #[arg(long)]
        pk: PathBuf,
        #[arg(long)]
        ballots: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// One committee member's partial decryption of the tally.
    PartialDecrypt {
        #[arg(long)]
        pk: PathBuf,
        #[arg(long)]
        share: PathBuf,
        #[arg(long)]
        tally: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// Combine partial decryptions into the plaintext total.
    Combine {
        #[arg(long)]
        pk: PathBuf,
        #[arg(long, num_args = 1..)]
        partials: Vec<PathBuf>,
        #[arg(long)]
        members: u32,
        #[arg(long)]
        threshold: u32,
    },
        /// Run a whole election, assert the result, write <out-dir>/election_<bits>.json
    Demo {
        #[arg(long = "voters-file")]
        voters_file: PathBuf,
        /// Number of yes votes (the rest vote no)
        #[arg(long)]
        yes: u32,
        #[arg(long, default_value_t = 1024)]
        bits: usize,
        #[arg(long, default_value = "fixtures")]
        out_dir: PathBuf,
        /// Generate a fresh key instead of using <out-dir>/dev_key_<bits>.json
        #[arg(long)]
        fresh: bool,
    },
    /// Re-verify a fixture file from disk.
    VerifyFixture {
        #[arg(long)]
        file: PathBuf,
    },
}

fn cmd_keygen(bits: usize, members: u32, threshold: u32, out: &Path, cached: bool) -> Res<()> {
    if threshold < 1 || threshold > members {
        return Err("need 1 <= threshold <= members".to_string());
    }
    let (pk, dk) = if cached {
        load_cached_key(format!("fixtures/dev_key_{bits}.json"))?
    } else {
        generate_safe_key(bits)
    };
    if pk.key_bits != bits {
        return Err(format!("key has {} bits, expected {bits}", pk.key_bits));
    }
    let k = pk.k_bytes();

    write_json(
        &out.join("public.json"),
        &PublicJson { key_bits: pk.key_bits, n: to_hex(&pk.n, k)? },
    )?;
    for s in deal_shares(&pk, &dk, members, threshold) {
        let j = ShareJson {
            index: s.index,
            members: s.members,
            threshold: s.threshold,
            n: to_hex(&pk.n, k)?,
            value: to_hex(&s.value, 2 * k)?,
        };
        write_json(&out.join(format!("share_{}.json", s.index)), &j)?;
    }
    println!(
        "wrote {}/public.json and share_1..share_{members}.json ({bits}-bit key, {threshold}-of-{members})",
        out.display()
    );
    Ok(())
}

fn cmd_vote(pk: &Path, election_id: &str, voter: &str, choice: u8, out: &Path) -> Res<()> {
    let pk = load_pk(pk)?;
    let ctx = Context {
        election_id: parse_election_id(election_id)?,
        voter: array_fixed::<20>(voter)?,
    };
    let ballot = make_ballot(&pk, &ctx, choice);
    write_json(out, &ballot_to_json(&pk, &ctx, &ballot)?)?;
    println!("wrote ballot for voter {voter} to {}", out.display());
    Ok(())
}

fn cmd_verify(pk: &Path, election_id: &str, ballot: &Path) -> Res<bool> {
    let pk = load_pk(pk)?;
    let eid = parse_election_id(election_id)?;
    let j: BallotJson = read_json(ballot)?;
    let (ctx, b) = ballot_from_json(&pk, &j)?;
    if ctx.election_id != eid {
        return Ok(false);
    }
    Ok(verify(&pk, &ctx, &b.c, &b.proof))
}

fn cmd_tally(pk: &Path, dir: &Path, out: &Path) -> Res<()> {
    let pk = load_pk(pk)?;
    let mut files: Vec<PathBuf> = fs::read_dir(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().map_or(false, |x| x == "json"))
        .collect();
    files.sort();
    if files.is_empty() {
        return Err(format!("no .json ballots in {}", dir.display()));
    }

    let mut ctxs: Vec<Context> = Vec::new();
    let mut ballots: Vec<Ballot> = Vec::new();
    let mut seen: HashSet<[u8; 20]> = HashSet::new();
    for f in &files {
        let j: BallotJson = read_json(f)?;
        let (ctx, b) = ballot_from_json(&pk, &j).map_err(|e| format!("{}: {e}", f.display()))?;
        if let Some(first) = ctxs.first() {
            if first.election_id != ctx.election_id {
                return Err(format!("{}: different electionId from the other ballots", f.display()));
            }
        }
        if !seen.insert(ctx.voter) {
            return Err(format!("{}: duplicate voter (one vote each)", f.display()));
        }
        ctxs.push(ctx);
        ballots.push(b);
    }

    let t = tally(&pk, &|i: usize| ctxs[i].clone(), &ballots)
        .map_err(|e| format!("{e} ({})", files[match &e {
            crypto_core::error::Error::InvalidBallot(i) => *i,
            _ => 0,
        }].display()))?;

    write_json(
        out,
        &TallyJson { tally: to_hex(&t, 2 * pk.k_bytes())?, ballot_count: ballots.len() },
    )?;
    println!("tally of {} verified ballots written to {}", ballots.len(), out.display());
    Ok(())
}

fn cmd_partial_decrypt(pk: &Path, share: &Path, tally_path: &Path, out: &Path) -> Res<()> {
    let pk = load_pk(pk)?;
    let k = pk.k_bytes();
    let sj: ShareJson = read_json(share)?;
    if big_fixed(&sj.n, k)? != pk.n {
        return Err("share belongs to a different key (n mismatch)".to_string());
    }
    let key_share = KeyShare {
        index: sj.index,
        value: big_fixed(&sj.value, 2 * k)?,
        members: sj.members,
        threshold: sj.threshold,
    };
    let tj: TallyJson = read_json(tally_path)?;
    let c = big_fixed(&tj.tally, 2 * k)?;
    if c == BigUint::from(0u8) || c >= pk.n2 {
        return Err("tally is out of range".to_string());
    }
    let p = partial_decrypt(&pk, &key_share, &c);
    write_json(out, &PartialJson { index: p.index, value: to_hex(&p.value, 2 * k)? })?;
    println!("member {} wrote partial decryption to {}", p.index, out.display());
    Ok(())
}

fn cmd_combine(pk: &Path, partial_files: &[PathBuf], members: u32, threshold: u32) -> Res<()> {
    let pk = load_pk(pk)?;
    let k = pk.k_bytes();
    let mut partials = Vec::new();
    for f in partial_files {
        let j: PartialJson = read_json(f)?;
        partials.push(Partial { index: j.index, value: big_fixed(&j.value, 2 * k)? });
    }
    let total = combine(&pk, &partials, members, threshold).map_err(|e| e.to_string())?;
    println!("{total}");
    Ok(())
}

fn run(cmd: Cmd) -> Res<ExitCode> {
    match cmd {
        Cmd::Keygen { bits, members, threshold, out, cached } => {
            cmd_keygen(bits, members, threshold, &out, cached)?
        }
        Cmd::Vote { pk, election_id, voter, choice, out } => {
            cmd_vote(&pk, &election_id, &voter, choice, &out)?
        }
        Cmd::Verify { pk, election_id, ballot } => {
            let ok = cmd_verify(&pk, &election_id, &ballot).unwrap_or(false);
            println!("{}", if ok { "valid" } else { "invalid" });
            return Ok(if ok { ExitCode::SUCCESS } else { ExitCode::FAILURE });
        }
        Cmd::Tally { pk, ballots, out } => cmd_tally(&pk, &ballots, &out)?,
        Cmd::PartialDecrypt { pk, share, tally, out } => {
            cmd_partial_decrypt(&pk, &share, &tally, &out)?
        }
        Cmd::Combine { pk, partials, members, threshold } => {
            cmd_combine(&pk, &partials, members, threshold)?
        }
        Cmd::Demo { voters_file, yes, bits, out_dir, fresh } => {
            demo::run_demo(&voters_file, yes, bits, fresh, &out_dir)?
        }
        Cmd::VerifyFixture { file } => demo::verify_fixture(&file)?,
    }
    Ok(ExitCode::SUCCESS)
}

fn main() -> ExitCode {
    match run(Cli::parse().cmd) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}