//! Serves the built client out of the binary when compiled with `--features ui`.
//! Dev builds skip embedding so the server compiles without `client/dist`.

#[cfg(feature = "ui")]
mod embedded {
    use axum::http::{header, StatusCode, Uri};
    use axum::response::{IntoResponse, Response};

    #[derive(rust_embed::RustEmbed)]
    #[folder = "../client/dist"]
    struct Asset;

    pub async fn static_handler(uri: Uri) -> Response {
        let path = uri.path().trim_start_matches('/');
        let path = if path.is_empty() { "index.html" } else { path };
        // Unknown non-asset paths fall back to the SPA shell.
        let (path, content) = match Asset::get(path) {
            Some(c) => (path, c),
            None => match Asset::get("index.html") {
                Some(c) => ("index.html", c),
                None => return (StatusCode::NOT_FOUND, "missing UI build").into_response(),
            },
        };
        let mime = mime_guess::from_path(path).first_or_octet_stream();
        ([(header::CONTENT_TYPE, mime.as_ref())], content.data).into_response()
    }
}

#[cfg(feature = "ui")]
pub use embedded::static_handler;

#[cfg(not(feature = "ui"))]
pub async fn static_handler() -> (axum::http::StatusCode, &'static str) {
    (
        axum::http::StatusCode::NOT_FOUND,
        "UI not embedded in this build; use the Vite dev server",
    )
}
