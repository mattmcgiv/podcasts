pub mod auth;
pub mod backend;
pub mod bootstrap;
pub mod browser;
pub mod classify;
pub mod coordinator;
pub mod db;
pub mod diagnostics;
pub mod directory;
pub mod error;
pub mod feedback;
pub mod feeds;
pub mod http;
pub mod jev;
pub mod jobs;
pub mod local_worker;
pub mod memory_gate;
pub mod models;
pub mod omlx_lock;
pub mod opml;
pub mod pipeline;
pub mod pipeline_pause;
pub mod power_gate;
pub mod progress;
pub mod range;
pub mod refresh;
pub mod server;
pub mod show_notes;
pub mod skip;
pub mod speaker;
pub mod storage;
pub mod transcribe;
pub mod usage;
pub mod voice;
pub mod youtube;

pub use backend::{Backend, DirectorySearcher, DisabledDirectory};
pub use db::Database;
pub use error::Error;
pub use feeds::{FeedFetcher, MockFeedFetcher};
pub use http::{HttpRequest, HttpResponse};

// DEPRECATED as of 1 October 2026. iPhone FFI only. Do not extend. See ios/DEPRECATED.md.
#[deprecated(
    since = "2026-10-01",
    note = "The iPhone FFI embedding is deprecated as of 1 October 2026. Do not extend. See ios/DEPRECATED.md."
)]
pub mod ffi;
