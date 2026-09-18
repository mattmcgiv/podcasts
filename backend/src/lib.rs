pub mod auth;
pub mod backend;
pub mod bootstrap;
pub mod browser;
pub mod local_worker;
pub mod jev;
pub mod memory_gate;
pub mod omlx_lock;
pub mod pipeline_pause;
pub mod power_gate;
pub mod classify;
pub mod coordinator;
pub mod db;
pub mod diagnostics;
pub mod directory;
pub mod error;
pub mod feeds;
pub mod http;
pub mod jobs;
pub mod models;
pub mod opml;
pub mod pipeline;
pub mod progress;
pub mod range;
pub mod refresh;
pub mod show_notes;
pub mod server;
pub mod skip;
pub mod speaker;
pub mod storage;
pub mod transcribe;
pub mod usage;

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
