use thiserror::Error;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum Error {
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Forbidden(String),
    #[error("{0}")]
    Unauthorized(String),
    #[error("not found")]
    NotFound,
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    Database(String),
    #[error("{0}")]
    Upstream(String),
}

impl Error {
    pub fn status_code(&self) -> u16 {
        match self {
            Error::Forbidden(_) => 403,
            Error::Unauthorized(_) => 401,
            Error::Invalid(_) => 422,
            Error::NotFound => 404,
            Error::Conflict(_) => 409,
            Error::Database(_) | Error::Upstream(_) => 500,
        }
    }

    pub fn message(&self) -> String {
        self.to_string()
    }
}

impl From<rusqlite::Error> for Error {
    fn from(value: rusqlite::Error) -> Self {
        Error::Database(value.to_string())
    }
}
