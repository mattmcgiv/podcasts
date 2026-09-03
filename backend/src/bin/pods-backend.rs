use pods_backend::{server, Backend, Database, DisabledDirectory, MockFeedFetcher};
use std::path::PathBuf;
use std::sync::Arc;

fn main() {
    let db_path = std::env::args().nth(1).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("pods.sqlite"));
    let db = Database::open(&db_path).expect("open database");
    let backend = Arc::new(Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(DisabledDirectory)));
    let addr = std::env::var("PODS_BIND").unwrap_or_else(|_| "127.0.0.1:18180".into());
    eprintln!("pods-backend listening on http://{addr}");
    let _listener = server::serve(backend, &addr).expect("listen");
    loop {
        std::thread::park();
    }
}
