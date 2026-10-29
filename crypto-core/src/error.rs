use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum Error {
    #[error("need at least {need} partial decryptions, got {have}")]
    NotEnoughPartials { have: usize, need: usize },
    #[error("duplicate partial index {0}")]
    DuplicateIndex(u32),
    #[error("partial index {0} is outside 1..=members")]
    BadIndex(u32),
    #[error("partial value is out of range or not invertible")]
    BadPartial,
    #[error("combined value is not of the form 1 + k*n (wrong or mismatched partials)")]
    NotDecryptable,
    #[error("invalid ballot at position {0}")]
    InvalidBallot(usize),
}