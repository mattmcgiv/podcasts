//! Opt-in, loopback-only browser fixture. Production authentication is unchanged.
use pods_backend::{Backend, Database, DisabledDirectory, HttpRequest};
use std::{path::PathBuf, sync::Arc};

#[test]
#[ignore = "operator supplies a disposable database below the system temp directory"]
fn serve_disposable_browser_library() {
    let path = PathBuf::from(std::env::var("PODS_BROWSER_TEST_DB").unwrap())
        .canonicalize()
        .unwrap();
    let temp = std::env::temp_dir().canonicalize().unwrap();
    assert!(
        path.starts_with(&temp),
        "Never disable authentication on the live library"
    );
    let artifacts = std::env::var("PODS_BROWSER_TEST_ARTIFACT_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| path.parent().unwrap().join("AdRemovalData"));
    std::fs::create_dir_all(&artifacts).unwrap();
    let artifacts = artifacts.canonicalize().unwrap();
    assert!(
        artifacts.starts_with(&temp),
        "Never serve live artifacts without authentication"
    );
    let mut backend = Backend::with_data_root(
        Database::open(&path).unwrap(),
        Arc::new(pods_backend::feeds::UreqFetcher::default()),
        Arc::new(DisabledDirectory),
        Some(artifacts),
    );
    backend.local = true;
    if std::env::var("PODS_BROWSER_TEST_REFRESH").as_deref() == Ok("1") {
        let response = backend.handle(HttpRequest::new("POST", "/api/refresh"));
        assert_eq!(response.status_code, 200);
        println!("Refresh: {}", String::from_utf8_lossy(&response.body));
    }
    let listener = pods_backend::server::serve(Arc::new(backend), "127.0.0.1:18181").unwrap();
    println!(
        "Disposable browser API: {} (expires in 30 minutes)",
        listener.local_addr().unwrap()
    );
    // This opt-in fixture has no worker and no cloud credentials.
    std::thread::sleep(std::time::Duration::from_secs(1800));
}
