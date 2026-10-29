use crypto_core::keygen::{generate_safe_key, save_dev_key};
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() != 3 {
        eprintln!("Usage: cargo run -p crypto-core --example generate_fixture -- <bits> <output_path>");
        std::process::exit(1);
    }

    let bits: usize = args[1].parse().expect("bits must be an integer");
    let output_path = &args[2];

    println!("Generating {bits}-bit development key...");
    let start = Instant::now();

    let (p, q, n) = generate_safe_key(bits);

    let elapsed = start.elapsed();

    save_dev_key(output_path, bits, &p, &q, &n)
        .expect("failed to save development key fixture");

    println!("Saved fixture: {output_path}");
    println!("Modulus bits: {}", n.bits());
    println!("Generation time: {:.2?}", elapsed);
    println!("WARNING: TEST KEYS ONLY; fixture contains secret factors.");
}