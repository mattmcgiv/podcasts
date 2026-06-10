use crate::error::AppError;
use crate::{now, AppState};
use serde::{Deserialize, Serialize};
use sha1::{Digest, Sha1};

#[derive(Debug, Serialize)]
pub struct DirectoryPodcast {
    pub title: String,
    pub author: String,
    pub feed_url: String,
    pub image_url: String,
    pub description: String,
    pub subscribed: bool,
}

#[derive(Deserialize)]
struct PiResponse {
    #[serde(default)]
    feeds: Vec<PiFeed>,
}

#[derive(Deserialize)]
struct PiFeed {
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    author: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    image: String,
    #[serde(default)]
    artwork: String,
}

/// Podcast Index request auth: Authorization = sha1hex(key + secret + unix-date).
fn auth_headers(key: &str, secret: &str, ts: i64) -> (String, String) {
    let hash = hex::encode(Sha1::digest(format!("{key}{secret}{ts}").as_bytes()));
    (ts.to_string(), hash)
}

/// None = directory not configured (no API key). Errors are real upstream failures.
pub async fn search(state: &AppState, query: &str) -> Result<Option<Vec<DirectoryPodcast>>, AppError> {
    let cfg = &state.cfg;
    if cfg.pi_key.is_empty() || cfg.pi_secret.is_empty() {
        return Ok(None);
    }
    let (date, auth) = auth_headers(&cfg.pi_key, &cfg.pi_secret, now());
    let url = format!("{}/search/byterm", cfg.pi_base);
    let resp = state
        .http
        .get(url)
        .query(&[("q", query), ("max", "20")])
        .header("X-Auth-Date", date)
        .header("X-Auth-Key", &cfg.pi_key)
        .header("Authorization", auth)
        .send()
        .await?
        .error_for_status()?;
    let body: PiResponse = resp.json().await?;
    Ok(Some(
        body.feeds
            .into_iter()
            .filter(|f| !f.url.is_empty())
            .map(|f| DirectoryPodcast {
                title: f.title,
                author: f.author,
                feed_url: f.url,
                image_url: if f.artwork.is_empty() { f.image } else { f.artwork },
                description: f.description,
                subscribed: false,
            })
            .collect(),
    ))
}

#[cfg(test)]
mod tests {
    use super::auth_headers;

    #[test]
    fn auth_header_is_sha1_of_key_secret_date() {
        // sha1("ks1700000000") computed independently
        let (date, auth) = auth_headers("k", "s", 1_700_000_000);
        assert_eq!(date, "1700000000");
        assert_eq!(auth.len(), 40);
        assert_eq!(auth, {
            use sha1::{Digest, Sha1};
            hex::encode(Sha1::digest(b"ks1700000000"))
        });
    }
}
