use pods_backend::db::Database;
use pods_backend::feeds::MockFeedFetcher;
use pods_backend::http::HttpRequest;
use pods_backend::Backend;
use serde_json::{json, Value};
use std::sync::Arc;

fn backend() -> Backend {
    let db = Database::open_in_memory().expect("db");
    let backend = Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(pods_backend::DisabledDirectory));
    backend.auth.enable_passkey("reset-secret", "https://pods.mcgiv.dev");
    backend
}

fn call(backend: &Backend, method: &str, target: &str, json_body: Option<Value>) -> pods_backend::HttpResponse {
    let mut req = HttpRequest::new(method, target);
    if let Some(body) = json_body {
        req = req.with_json(&body);
    }
    backend.handle(req)
}

fn call_cookie(backend: &Backend, method: &str, target: &str, json_body: Option<Value>, cookie: &str) -> pods_backend::HttpResponse {
    let mut req = HttpRequest::new(method, target);
    if let Some(body) = json_body {
        req = req.with_json(&body);
    }
    req = req.with_header("cookie", cookie);
    backend.handle(req)
}

fn set_cookie(response: &pods_backend::HttpResponse) -> Option<String> {
    response.headers.get("set-cookie").cloned()
}

fn cookie_pair(set_cookie: &str) -> String {
    set_cookie.split(';').next().unwrap().trim().to_string()
}

#[test]
fn test_auth_off_recent_is_200() {
    let db = Database::open_in_memory().expect("db");
    let backend = Backend::new(db, Arc::new(MockFeedFetcher::default()), Arc::new(pods_backend::DisabledDirectory));
    let response = call(&backend, "GET", "/api/recent", None);
    assert_eq!(response.status_code, 200);
}

#[test]
fn test_passkey_mode_recent_is_401_without_cookie() {
    let backend = backend();
    let response = call(&backend, "GET", "/api/recent", None);
    assert_eq!(response.status_code, 401);
}

#[test]
fn test_register_without_enroll_token_is_rejected() {
    let backend = backend();
    let response = call(&backend, "POST", "/api/auth/register/options", Some(json!({})));
    assert_eq!(response.status_code, 401);
}

#[test]
fn test_reset_requires_header() {
    let backend = backend();
    let response = call(&backend, "POST", "/api/internal/passkey-reset", None);
    assert_eq!(response.status_code, 401);
}

#[test]
fn test_reset_then_enroll_then_recent() {
    let backend = backend();
    let mut req = HttpRequest::new("POST", "/api/internal/passkey-reset");
    req = req.with_header("x-pods-reset-key", "reset-secret");
    let reset = backend.handle(req);
    assert_eq!(reset.status_code, 200);
    let body: Value = serde_json::from_slice(&reset.body).unwrap();
    let enroll_url = body["enroll_url"].as_str().unwrap();
    assert!(enroll_url.starts_with("https://pods.mcgiv.dev/#enroll="));
    let token = enroll_url.split("#enroll=").nth(1).unwrap();

    let options = call(
        &backend,
        "POST",
        "/api/auth/register/options",
        Some(json!({ "token": token })),
    );
    assert_eq!(options.status_code, 200);
    let options_body: Value = serde_json::from_slice(&options.body).unwrap();
    let state_id = options_body["state_id"].as_str().unwrap();

    let registered = call(
        &backend,
        "POST",
        "/api/auth/register",
        Some(json!({
            "state_id": state_id,
            "credential": { "id": "cred-1" }
        })),
    );
    assert_eq!(registered.status_code, 201);
    let cookie = cookie_pair(set_cookie(&registered).as_deref().unwrap());

    let recent = call_cookie(&backend, "GET", "/api/recent", None, &cookie);
    assert_eq!(recent.status_code, 200);

    let second = call(
        &backend,
        "POST",
        "/api/auth/register/options",
        Some(json!({ "token": token })),
    );
    assert_eq!(second.status_code, 401);
}

#[test]
fn test_reset_revokes_sessions() {
    let backend = backend();
    let mut req = HttpRequest::new("POST", "/api/internal/passkey-reset");
    req = req.with_header("x-pods-reset-key", "reset-secret");
    let reset = backend.handle(req);
    let body: Value = serde_json::from_slice(&reset.body).unwrap();
    let token = body["enroll_url"].as_str().unwrap().split("#enroll=").nth(1).unwrap();
    let options: Value = serde_json::from_slice(
        &call(&backend, "POST", "/api/auth/register/options", Some(json!({ "token": token }))).body,
    )
    .unwrap();
    let registered = call(
        &backend,
        "POST",
        "/api/auth/register",
        Some(json!({
            "state_id": options["state_id"],
            "credential": { "id": "cred-1" }
        })),
    );
    let cookie = cookie_pair(set_cookie(&registered).as_deref().unwrap());
    assert_eq!(call_cookie(&backend, "GET", "/api/recent", None, &cookie).status_code, 200);

    let mut reset2 = HttpRequest::new("POST", "/api/internal/passkey-reset");
    reset2 = reset2.with_header("x-pods-reset-key", "reset-secret");
    assert_eq!(backend.handle(reset2).status_code, 200);
    assert_eq!(call_cookie(&backend, "GET", "/api/recent", None, &cookie).status_code, 401);
}

#[test]
fn test_login_after_enroll() {
    let backend = backend();
    let mut req = HttpRequest::new("POST", "/api/internal/passkey-reset");
    req = req.with_header("x-pods-reset-key", "reset-secret");
    let reset = backend.handle(req);
    let token = serde_json::from_slice::<Value>(&reset.body).unwrap()["enroll_url"]
        .as_str()
        .unwrap()
        .split("#enroll=")
        .nth(1)
        .unwrap()
        .to_string();
    let options: Value = serde_json::from_slice(
        &call(&backend, "POST", "/api/auth/register/options", Some(json!({ "token": token }))).body,
    )
    .unwrap();
    call(
        &backend,
        "POST",
        "/api/auth/register",
        Some(json!({
            "state_id": options["state_id"],
            "credential": { "id": "cred-1" }
        })),
    );

    let login_options = call(&backend, "POST", "/api/auth/login/options", Some(json!({})));
    assert_eq!(login_options.status_code, 200);
    let login_body: Value = serde_json::from_slice(&login_options.body).unwrap();
    let logged = call(
        &backend,
        "POST",
        "/api/auth/login",
        Some(json!({
            "state_id": login_body["state_id"],
            "credential": { "id": "cred-1" }
        })),
    );
    assert_eq!(logged.status_code, 200);
    let cookie = cookie_pair(set_cookie(&logged).as_deref().unwrap());
    assert_eq!(call_cookie(&backend, "GET", "/api/recent", None, &cookie).status_code, 200);
}
