use pods_backend::directory::configured_directory;
use pods_backend::feeds::UreqFetcher;
use pods_backend::{server, Backend, Database};
use std::path::PathBuf;
use std::sync::Arc;

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--check-local-model") {
        let segments = vec![
            pods_backend::local_worker::Segment {
                id: "s0".into(),
                start: 0.0,
                end: 4.0,
                text: "This episode is sponsored by Acme. Use code PODS for twenty percent off."
                    .into(),
            },
            pods_backend::local_worker::Segment {
                id: "s1".into(),
                start: 4.0,
                end: 8.0,
                text: "Now we discuss the history of computing and its early pioneers.".into(),
            },
        ];
        let permit = match pods_backend::omlx_lock::acquire_pods(
            pods_backend::omlx_lock::PURPOSE_CLASSIFICATION,
            pods_backend::local_worker::MODEL,
        ) {
            Ok(permit) => permit,
            Err(error) => {
                eprintln!("Local model contract failed: {error}");
                std::process::exit(1);
            }
        };
        let result = pods_backend::local_worker::classify_window(&segments, 0, 2, 12, &permit);
        match result {
            Ok(labels) if labels[0].label == "ad" && labels[1].label == "content" => {
                println!("Local model contract passed (synthetic input).")
            }
            Err(error) => {
                eprintln!("Local model contract failed: {error}");
                std::process::exit(1);
            }
            _ => {
                eprintln!("Local model returned incorrect synthetic labels.");
                std::process::exit(1);
            }
        }
        return;
    }
    let db_path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("pods.sqlite"));
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
    let addr = std::env::var("PODS_BIND").unwrap_or_else(|_| "127.0.0.1:18180".into());
    eprintln!("pods-backend listening on http://{addr}");
    let _listener = server::serve(backend, &addr).expect("listen");
    loop {
        std::thread::park();
    }
}
