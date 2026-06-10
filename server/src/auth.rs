use crate::error::AppError;
use crate::AppState;
use axum::extract::{Request, State};
use axum::middleware::Next;
use axum::response::Response;
use subtle::ConstantTimeEq;

pub fn token_matches(presented: &str, expected: &str) -> bool {
    if expected.is_empty() {
        return false;
    }
    presented.as_bytes().ct_eq(expected.as_bytes()).into()
}

pub async fn require_bearer(
    State(state): State<AppState>,
    req: Request,
    next: Next,
) -> Result<Response, AppError> {
    let presented = req
        .headers()
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if token_matches(presented, &state.cfg.api_token) {
        Ok(next.run(req).await)
    } else {
        Err(AppError::Unauthorized)
    }
}

#[cfg(test)]
mod tests {
    use super::token_matches;

    #[test]
    fn rejects_empty_expected_token() {
        assert!(!token_matches("", ""));
        assert!(!token_matches("x", ""));
    }

    #[test]
    fn compares_tokens() {
        assert!(token_matches("secret", "secret"));
        assert!(!token_matches("secret!", "secret"));
        assert!(!token_matches("", "secret"));
    }
}
