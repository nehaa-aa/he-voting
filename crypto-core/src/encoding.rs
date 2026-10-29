use num_bigint::BigUint;

/// Convert a non-negative integer to exactly `width` bytes using big-endian
/// encoding. Leading zero bytes are preserved.
pub fn bigint_to_bytes(value: &BigUint, width: usize) -> Option<Vec<u8>> {
    let bytes = value.to_bytes_be();

    if bytes.len() > width {
        return None;
    }

    let mut output = vec![0u8; width - bytes.len()];
    output.extend_from_slice(&bytes);
    Some(output)
}

/// Convert big-endian bytes to a non-negative integer.
pub fn bytes_to_bigint(bytes: &[u8], width: usize) -> Option<BigUint> {
    if bytes.len() != width {
        return None;
    }

    Some(BigUint::from_bytes_be(bytes))
}

/// Encode bytes as a 0x-prefixed hexadecimal string.
pub fn bytes_to_hex(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

/// Decode a 0x-prefixed hexadecimal string into bytes.
/// Rejects strings without the prefix or with invalid hexadecimal.
pub fn hex_to_bytes(value: &str) -> Result<Vec<u8>, String> {
    let raw = value
        .strip_prefix("0x")
        .ok_or_else(|| "missing 0x prefix".to_string())?;

    hex::decode(raw).map_err(|err| err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_at_k_bytes() {
        let value = BigUint::from(0x1234u32);
        let encoded = bigint_to_bytes(&value, 4).unwrap();

        assert_eq!(encoded, vec![0, 0, 0x12, 0x34]);
        assert_eq!(bytes_to_bigint(&encoded, 4), Some(value));
    }

    #[test]
    fn round_trip_at_2k_bytes() {
        let value = BigUint::from(0x1234u32);
        let encoded = bigint_to_bytes(&value, 8).unwrap();

        assert_eq!(encoded, vec![0, 0, 0, 0, 0, 0, 0x12, 0x34]);
        assert_eq!(bytes_to_bigint(&encoded, 8), Some(value));
    }

    #[test]
    fn leading_zero_bytes_are_preserved() {
        let bytes = vec![0, 0, 0x12, 0x34];
        let value = bytes_to_bigint(&bytes, bytes.len()).unwrap();
        let encoded = bigint_to_bytes(&value, bytes.len()).unwrap();

        assert_eq!(encoded, bytes);
    }

    #[test]
    fn rejects_integer_that_does_not_fit() {
        let value = BigUint::from(0x1234u32);
        assert!(bigint_to_bytes(&value, 1).is_none());
    }

    #[test]
    fn rejects_wrong_byte_length() {
        let bytes = vec![0x12, 0x34];

        assert!(bytes_to_bigint(&bytes, 4).is_none());
        assert!(bytes_to_bigint(&bytes, 1).is_none());
    }

    #[test]
    fn hex_round_trip_preserves_leading_zeros() {
        let bytes = vec![0, 0, 0x12, 0x34];
        let encoded = bytes_to_hex(&bytes);

        assert_eq!(encoded, "0x00001234");
        assert_eq!(hex_to_bytes(&encoded).unwrap(), bytes);
    }

    #[test]
    fn hex_requires_prefix() {
        assert!(hex_to_bytes("1234").is_err());
    }

    #[test]
    fn hex_rejects_invalid_digits() {
        assert!(hex_to_bytes("0x12zz").is_err());
    }
}