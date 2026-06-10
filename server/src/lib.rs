pub mod api;
pub mod assets;
pub mod auth;
pub mod db;
pub mod error;
pub mod feeds;
pub mod opml;
pub mod podcastindex;

use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub pool: sqlx::SqlitePool,
    pub http: reqwest::Client,
    pub cfg: Arc<Config>,
    pub refresh_lock: Arc<tokio::sync::Mutex<()>>,
}

#[derive(Clone)]
pub struct Config {
    pub api_token: String,
    pub pi_key: String,
    pub pi_secret: String,
    pub pi_base: String,
    pub db_path: String,
    pub bind_addr: String,
}

impl Config {
    pub fn from_env() -> Self {
        let var = |k: &str, d: &str| std::env::var(k).unwrap_or_else(|_| d.to_string());
        Self {
            api_token: var("API_TOKEN", ""),
            pi_key: var("PODCASTINDEX_KEY", ""),
            pi_secret: var("PODCASTINDEX_SECRET", ""),
            pi_base: var("PODCASTINDEX_BASE_URL", "https://api.podcastindex.org/api/1.0"),
            db_path: var("DATABASE_PATH", "data/pods.sqlite"),
            bind_addr: var("BIND_ADDR", "0.0.0.0:8080"),
        }
    }
}

pub fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(concat!("Pods/", env!("CARGO_PKG_VERSION")))
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .expect("http client")
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn build_state(pool: sqlx::SqlitePool, cfg: Config) -> AppState {
    AppState {
        pool,
        http: http_client(),
        cfg: Arc::new(cfg),
        refresh_lock: Arc::new(tokio::sync::Mutex::new(())),
    }
}
