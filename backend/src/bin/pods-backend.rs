use pods_backend::directory::configured_directory;
use pods_backend::feeds::UreqFetcher;
use pods_backend::{server, Backend, Database};
use std::path::PathBuf;
use std::sync::Arc;

fn main() {
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
