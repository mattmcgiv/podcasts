use pods_server::{api, build_state, db, feeds, Config};

#[tokio::main]
async fn main() {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "pods_server=info".into()),
        )
        .init();

    let cfg = Config::from_env();
    let pool = db::init(&cfg.db_path).await.expect("database init");
    let bind = cfg.bind_addr.clone();
    let state = build_state(pool, cfg);

    // Background feed refresher: first pass shortly after boot, then every 15 min.
    let refresher = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        loop {
            let (ok, errs) = feeds::refresh_all(&refresher).await;
            tracing::info!(ok, errs, "feed refresh pass");
            tokio::time::sleep(std::time::Duration::from_secs(900)).await;
        }
    });

    let app = api::router(state);
    let listener = tokio::net::TcpListener::bind(&bind).await.expect("bind");
    tracing::info!(%bind, "pods-server listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .expect("server");
}
