use sha3::{Digest, Keccak256};

/// Keccak-256 (the Ethereum hash, NOT NIST SHA3-256).
pub fn keccak256(data: &[u8]) -> [u8; 32] {
    let digest = Keccak256::digest(data);
    let mut out = [0u8; 32];
    out.copy_from_slice(digest.as_slice());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keccak_of_empty_input_matches_known_vector() {
        // Well-known Keccak-256("") value (also what Solidity gives).
        assert_eq!(
            hex::encode(keccak256(b"")),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        );
    }
}