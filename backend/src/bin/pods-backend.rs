use pods_backend::directory::configured_directory;
use pods_backend::feeds::UreqFetcher;
use pods_backend::{server, Backend, Database};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::Arc;

fn check_local_model() -> i32 {
    let segments = vec![
        pods_backend::local_worker::Segment {
            id: "s0".into(),
            start: 0.0,
            end: 4.0,
            text: "This episode is sponsored by Acme. Use code PODS for twenty percent off.".into(),
        },
        pods_backend::local_worker::Segment {
            id: "s1".into(),
            start: 4.0,
            end: 8.0,
            text: "Now we discuss the history of computing and its early pioneers.".into(),
        },
    ];
    let permit = match pods_backend::omlx_lock::acquire_chat(
        pods_backend::omlx_lock::PURPOSE_CLASSIFICATION,
        pods_backend::local_worker::MODEL,
    ) {
        Ok(permit) => permit,
        Err(error) => {
            eprintln!("Local model contract failed: {error}");
            return 1;
        }
    };
    match pods_backend::local_worker::classify_window(&segments, 0, 2, 12, &permit) {
        Ok(labels) if labels[0].label == "ad" && labels[1].label == "content" => {
            println!("Local model contract passed (synthetic input).");
            0
        }
        Err(error) => {
            eprintln!("Local model contract failed: {error}");
            1
        }
        _ => {
            eprintln!("Local model returned incorrect synthetic labels.");
            1
        }
    }
}

fn launch_backend(db_path: PathBuf, bind: &str) -> (Arc<Backend>, TcpListener) {
    let db = Database::open(&db_path).expect("open database");
    let data_root = db_path.parent().map(|p| p.join("AdRemovalData"));
    let mut backend = Backend::with_data_root(
        db,
        Arc::new(UreqFetcher::default()),
        configured_directory(),
        data_root,
    );
    backend.set_pipeline_config(pods_backend::pipeline::PipelineConfig::from_env());
    backend.local = std::env::var("PODS_LOCAL").as_deref() != Ok("0");
    if backend.local {
        assert_eq!(
            std::env::var("PODS_AUTH_MODE").as_deref(),
            Ok("passkey"),
            "Mac browser service requires PODS_AUTH_MODE=passkey"
        );
        backend.pipeline.background_refresh_secs = 1800;
    }
    let backend = Arc::new(backend);
    pods_backend::auth::configure_from_env(&backend.auth).expect("configure auth");
    backend.start_runtime();
    let listener = server::serve(backend.clone(), bind).expect("listen");
    eprintln!("pods-backend listening on http://{bind}");
    (backend, listener)
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--check-local-model") {
        std::process::exit(check_local_model());
    }
    let db_path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("pods.sqlite"));
    let addr = std::env::var("PODS_BIND").unwrap_or_else(|_| "127.0.0.1:18180".into());
    let (_backend, listener) = launch_backend(db_path, &addr);
    let _listener = listener;
    loop {
        std::thread::park();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_backend_serves_http_on_loopback() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("pods.sqlite");
        let prev_local = std::env::var("PODS_LOCAL").ok();
        let prev_auth = std::env::var("PODS_AUTH_MODE").ok();
        std::env::set_var("PODS_LOCAL", "0");
        std::env::set_var("PODS_AUTH_MODE", "off");
        let (backend, listener) = launch_backend(db, "127.0.0.1:0");
        let addr = listener.local_addr().unwrap();
        assert!(addr.port() != 0);
        backend.stop_runtime();
        drop(listener);
        match prev_local {
            Some(value) => std::env::set_var("PODS_LOCAL", value),
            None => std::env::remove_var("PODS_LOCAL"),
        }
        match prev_auth {
            Some(value) => std::env::set_var("PODS_AUTH_MODE", value),
            None => std::env::remove_var("PODS_AUTH_MODE"),
        }
    }
}
