use crate::db::{self, Database};
use crate::error::Error;
use crate::http::{HttpRequest, HttpResponse};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use uuid::Uuid;

pub const SESSION_COOKIE: &str = "pods_session";
const SESSION_TTL_SECS: i64 = 30 * 24 * 60 * 60;
const ENROLL_TTL_SECS: i64 = 30 * 60;
const WEBAUTHN_STATE_TTL_SECS: i64 = 10 * 60;
const USER_HANDLE: &str = "matt";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthMode {
    Off,
    Passkey,
}

pub trait PasskeyEngine: Send + Sync {
    fn start_registration(&self, exclude_ids: &[String]) -> Result<(Value, Value), Error>;
    fn finish_registration(&self, state: &Value, response: &Value) -> Result<StoredPasskey, Error>;
    fn start_authentication(&self, credentials: &[StoredPasskey]) -> Result<(Value, Value), Error>;
    fn finish_authentication(&self, state: &Value, response: &Value) -> Result<String, Error>;
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StoredPasskey {
    pub credential_id: String,
    pub public_key_json: String,
}

#[derive(Default)]
pub struct ScriptedPasskey;

impl PasskeyEngine for ScriptedPasskey {
    fn start_registration(&self, _exclude_ids: &[String]) -> Result<(Value, Value), Error> {
        Ok((
            json!({
                "challenge": "scripted-register",
                "rp": { "id": "localhost", "name": "Pods" },
                "user": { "id": "bWF0dA", "name": USER_HANDLE, "displayName": "Matt" },
                "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }],
                "authenticatorSelection": {
                    "residentKey": "required",
                    "userVerification": "required"
                }
            }),
            json!({ "kind": "register" }),
        ))
    }

    fn finish_registration(&self, _state: &Value, response: &Value) -> Result<StoredPasskey, Error> {
        let credential_id = response
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Invalid("passkey id is required".into()))?
            .to_string();
        if credential_id.trim().is_empty() {
            return Err(Error::Invalid("passkey id is required".into()));
        }
        Ok(StoredPasskey {
            public_key_json: credential_id.clone(),
            credential_id,
        })
    }

    fn start_authentication(&self, credentials: &[StoredPasskey]) -> Result<(Value, Value), Error> {
        if credentials.is_empty() {
            return Err(Error::Unauthorized("no passkey is enrolled".into()));
        }
        Ok((
            json!({
                "challenge": "scripted-login",
                "rpId": "localhost",
                "allowCredentials": credentials.iter().map(|c| json!({
                    "type": "public-key",
                    "id": c.credential_id
                })).collect::<Vec<_>>(),
                "userVerification": "required"
            }),
            json!({ "kind": "login" }),
        ))
    }

    fn finish_authentication(&self, _state: &Value, response: &Value) -> Result<String, Error> {
        let credential_id = response
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Unauthorized("passkey assertion is invalid".into()))?
            .to_string();
        Ok(credential_id)
    }
}

#[cfg(feature = "passkey")]
pub struct WebauthnEngine {
    inner: webauthn_rs::Webauthn,
}

#[cfg(feature = "passkey")]
impl WebauthnEngine {
    pub fn new(rp_id: &str, origin: &str) -> Result<Self, Error> {
        let origin = url::Url::parse(origin).map_err(|e| Error::Invalid(e.to_string()))?;
        let builder = webauthn_rs::WebauthnBuilder::new(rp_id, &origin)
            .map_err(|e| Error::Invalid(e.to_string()))?
            .rp_name("Pods");
        let inner = builder.build().map_err(|e| Error::Invalid(e.to_string()))?;
        Ok(Self { inner })
    }
}

#[cfg(feature = "passkey")]
impl PasskeyEngine for WebauthnEngine {
    fn start_registration(&self, exclude_ids: &[String]) -> Result<(Value, Value), Error> {
        let exclude = exclude_ids
            .iter()
            .filter_map(|id| {
                let bytes = hex::decode(id).ok()?;
                Some(webauthn_rs::prelude::CredentialID::from(bytes))
            })
            .collect::<Vec<_>>();
        let user_id = uuid::Uuid::parse_str("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
            .expect("fixed user uuid");
        let (options, state) = self
            .inner
            .start_passkey_registration(user_id, USER_HANDLE, "Matt", Some(exclude))
            .map_err(|e| Error::Invalid(e.to_string()))?;
        Ok((
            serde_json::to_value(options).map_err(|e| Error::Invalid(e.to_string()))?,
            serde_json::to_value(state).map_err(|e| Error::Invalid(e.to_string()))?,
        ))
    }

    fn finish_registration(&self, state: &Value, response: &Value) -> Result<StoredPasskey, Error> {
        let state: webauthn_rs::prelude::PasskeyRegistration =
            serde_json::from_value(state.clone()).map_err(|e| Error::Invalid(e.to_string()))?;
        let response: webauthn_rs::prelude::RegisterPublicKeyCredential =
            serde_json::from_value(response.clone()).map_err(|e| Error::Invalid(e.to_string()))?;
        let passkey = self
            .inner
            .finish_passkey_registration(&response, &state)
            .map_err(|e| Error::Unauthorized(e.to_string()))?;
        let credential_id = hex::encode(passkey.cred_id().as_ref());
        let public_key_json =
            serde_json::to_string(&passkey).map_err(|e| Error::Invalid(e.to_string()))?;
        Ok(StoredPasskey {
            credential_id,
            public_key_json,
        })
    }

    fn start_authentication(&self, credentials: &[StoredPasskey]) -> Result<(Value, Value), Error> {
        let passkeys: Vec<webauthn_rs::prelude::Passkey> = credentials
            .iter()
            .filter_map(|c| serde_json::from_str(&c.public_key_json).ok())
            .collect();
        if passkeys.is_empty() {
            return Err(Error::Unauthorized("no passkey is enrolled".into()));
        }
        let (options, state) = self
            .inner
            .start_passkey_authentication(&passkeys)
            .map_err(|e| Error::Invalid(e.to_string()))?;
        Ok((
            serde_json::to_value(options).map_err(|e| Error::Invalid(e.to_string()))?,
            serde_json::to_value(state).map_err(|e| Error::Invalid(e.to_string()))?,
        ))
    }

    fn finish_authentication(&self, state: &Value, response: &Value) -> Result<String, Error> {
        let state: webauthn_rs::prelude::PasskeyAuthentication =
            serde_json::from_value(state.clone()).map_err(|e| Error::Invalid(e.to_string()))?;
        let response: webauthn_rs::prelude::PublicKeyCredential =
            serde_json::from_value(response.clone()).map_err(|e| Error::Invalid(e.to_string()))?;
        let result = self
            .inner
            .finish_passkey_authentication(&response, &state)
            .map_err(|e| Error::Unauthorized(e.to_string()))?;
        Ok(hex::encode(result.cred_id().as_ref()))
    }
}

pub struct Auth {
    mode: Mutex<AuthMode>,
    reset_key_hash: Mutex<String>,
    origin: Mutex<String>,
    cookie_secure: Mutex<bool>,
    engine: Mutex<Arc<dyn PasskeyEngine>>,
}

impl Default for Auth {
    fn default() -> Self {
        Self {
            mode: Mutex::new(AuthMode::Off),
            reset_key_hash: Mutex::new(String::new()),
            origin: Mutex::new("http://127.0.0.1:18180".into()),
            cookie_secure: Mutex::new(false),
            engine: Mutex::new(Arc::new(ScriptedPasskey)),
        }
    }
}

impl Auth {
    pub fn enabled(&self) -> bool {
        *self.mode.lock().unwrap() == AuthMode::Passkey
    }

    pub fn origin(&self) -> String {
        self.origin.lock().unwrap().clone()
    }

    pub fn configure(&self, mode: AuthMode, reset_key: &str, origin: &str, engine: Arc<dyn PasskeyEngine>) {
        *self.mode.lock().unwrap() = mode;
        *self.reset_key_hash.lock().unwrap() = hash_secret(reset_key);
        *self.origin.lock().unwrap() = origin.to_string();
        *self.cookie_secure.lock().unwrap() = origin.starts_with("https://");
        *self.engine.lock().unwrap() = engine;
    }

    pub fn enable_passkey(&self, reset_key: &str, origin: &str) {
        self.configure(AuthMode::Passkey, reset_key, origin, Arc::new(ScriptedPasskey));
    }

    fn engine(&self) -> Arc<dyn PasskeyEngine> {
        self.engine.lock().unwrap().clone()
    }

    fn reset_key_matches(&self, presented: &str) -> bool {
        let expected = self.reset_key_hash.lock().unwrap().clone();
        !expected.is_empty() && expected == hash_secret(presented)
    }

    fn cookie_secure(&self) -> bool {
        *self.cookie_secure.lock().unwrap()
    }
}

pub fn hash_secret(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}

pub fn load_reset_key() -> Result<String, Error> {
    if let Ok(value) = std::env::var("PODS_RESET_KEY") {
        let value = value.trim().to_string();
        if !value.is_empty() {
            return Ok(value);
        }
    }
    let path = std::env::var("PODS_RESET_KEY_FILE").unwrap_or_else(|_| "/etc/pods/reset.key".into());
    let value = std::fs::read_to_string(&path)
        .map_err(|_| Error::Invalid("reset key file is missing".into()))?;
    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(Error::Invalid("reset key file is empty".into()));
    }
    Ok(value)
}

#[cfg(feature = "passkey")]
pub fn configure_from_env(auth: &Auth) -> Result<(), Error> {
    let mode = std::env::var("PODS_AUTH_MODE").unwrap_or_default();
    if mode.trim() != "passkey" {
        return Ok(());
    }
    let origin = std::env::var("PODS_ORIGIN").unwrap_or_else(|_| "https://pods.mcgiv.dev".into());
    let rp_id = std::env::var("PODS_RP_ID").unwrap_or_else(|_| "pods.mcgiv.dev".into());
    let reset_key = load_reset_key()?;
    let engine = WebauthnEngine::new(rp_id.trim(), origin.trim())?;
    auth.configure(AuthMode::Passkey, &reset_key, origin.trim(), Arc::new(engine));
    Ok(())
}

pub fn trusted_origins_from_env() -> Vec<String> {
    std::env::var("PODS_TRUSTED_ORIGINS")
        .ok()
        .map(|raw| {
            raw.split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        })
        .filter(|v: &Vec<String>| !v.is_empty())
        .unwrap_or_else(|| vec!["http://127.0.0.1:18180".into()])
}

pub fn is_public_auth_path(path: &str, method: &str) -> bool {
    matches!(
        (method, path),
        ("GET", "/api/auth/status")
            | ("POST", "/api/auth/login/options")
            | ("POST", "/api/auth/login")
            | ("POST", "/api/auth/register/options")
            | ("POST", "/api/auth/register")
            | ("POST", "/api/internal/passkey-reset")
            | ("POST", "/api/auth/logout")
    )
}

pub fn session_cookie_header(token: &str, secure: bool) -> String {
    let mut value = format!(
        "{SESSION_COOKIE}={token}; HttpOnly; SameSite=Lax; Path=/; Max-Age={SESSION_TTL_SECS}"
    );
    if secure {
        value.push_str("; Secure");
    }
    value
}

pub fn clear_session_cookie(secure: bool) -> String {
    let mut value = format!("{SESSION_COOKIE}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0");
    if secure {
        value.push_str("; Secure");
    }
    value
}

pub fn enrolled(db: &Database) -> Result<bool, Error> {
    Ok(db
        .scalar_i64("SELECT COUNT(*) FROM passkey_credentials", [])?
        .unwrap_or(0)
        > 0)
}

pub fn valid_session(db: &Database, token: Option<&str>) -> Result<bool, Error> {
    let Some(token) = token.filter(|t| !t.is_empty()) else {
        return Ok(false);
    };
    let hash = hash_secret(token);
    let now = db::now_unix();
    let found = db.scalar_i64(
        "SELECT 1 FROM auth_sessions WHERE token_hash = ? AND expires_at > ?",
        rusqlite::params![hash, now],
    )?;
    if found.is_some() {
        let _ = db.execute(
            "UPDATE auth_sessions SET expires_at = ? WHERE token_hash = ?",
            rusqlite::params![now + SESSION_TTL_SECS, hash],
        );
        Ok(true)
    } else {
        Ok(false)
    }
}

pub fn require_session(auth: &Auth, db: &Database, request: &HttpRequest) -> Result<(), Error> {
    if !auth.enabled() {
        return Ok(());
    }
    if is_public_auth_path(&request.path(), request.method.as_str()) {
        return Ok(());
    }
    let token = HttpResponse::cookie(request, SESSION_COOKIE);
    if valid_session(db, token.as_deref())? {
        Ok(())
    } else {
        Err(Error::Unauthorized("sign in required".into()))
    }
}

fn insert_session(db: &Database) -> Result<String, Error> {
    let token = Uuid::new_v4().to_string();
    let now = db::now_unix();
    db.execute(
        "INSERT INTO auth_sessions (token_hash, created_at, expires_at) VALUES (?, ?, ?)",
        rusqlite::params![hash_secret(&token), now, now + SESSION_TTL_SECS],
    )?;
    Ok(token)
}

fn enroll_token_valid(db: &Database, token: &str) -> Result<(), Error> {
    let hash = hash_secret(token);
    let now = db::now_unix();
    let used: Option<i64> = {
        let conn = db.lock()?;
        conn.query_row(
            "SELECT used FROM auth_enroll_tokens WHERE token_hash = ? AND expires_at > ?",
            rusqlite::params![hash, now],
            |row| row.get(0),
        )
        .optional()?
    };
    match used {
        Some(0) => Ok(()),
        _ => Err(Error::Unauthorized("enroll token is invalid".into())),
    }
}

fn consume_enroll_token(db: &Database, token: &str) -> Result<(), Error> {
    enroll_token_valid(db, token)?;
    let hash = hash_secret(token);
    let changed = db.execute(
        "UPDATE auth_enroll_tokens SET used = 1 WHERE token_hash = ? AND used = 0",
        rusqlite::params![hash],
    )?;
    if changed == 1 {
        Ok(())
    } else {
        Err(Error::Unauthorized("enroll token is invalid".into()))
    }
}

fn put_webauthn_state(db: &Database, kind: &str, state: &Value, enroll_token: Option<&str>) -> Result<String, Error> {
    let id = Uuid::new_v4().to_string();
    let now = db::now_unix();
    let wrapped = json!({ "state": state, "enroll_token": enroll_token });
    db.execute(
        "INSERT INTO auth_webauthn_state (id, kind, state_json, expires_at) VALUES (?, ?, ?, ?)",
        rusqlite::params![id, kind, wrapped.to_string(), now + WEBAUTHN_STATE_TTL_SECS],
    )?;
    Ok(id)
}

fn take_webauthn_state(db: &Database, id: &str, kind: &str) -> Result<Value, Error> {
    let now = db::now_unix();
    let conn = db.lock()?;
    let raw: Option<String> = conn
        .query_row(
            "SELECT state_json FROM auth_webauthn_state WHERE id = ? AND kind = ? AND expires_at > ?",
            rusqlite::params![id, kind, now],
            |row| row.get(0),
        )
        .optional()?;
    let Some(raw) = raw else {
        return Err(Error::Unauthorized("webauthn state is invalid".into()));
    };
    conn.execute(
        "DELETE FROM auth_webauthn_state WHERE id = ?",
        rusqlite::params![id],
    )?;
    serde_json::from_str(&raw).map_err(|e| Error::Invalid(e.to_string()))
}

fn list_passkeys(db: &Database) -> Result<Vec<StoredPasskey>, Error> {
    let conn = db.lock()?;
    let mut stmt = conn.prepare("SELECT credential_id, public_key_json FROM passkey_credentials")?;
    let rows = stmt.query_map([], |row| {
        Ok(StoredPasskey {
            credential_id: row.get(0)?,
            public_key_json: row.get(1)?,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn webauthn_public_key(options: Value) -> Value {
    options.get("publicKey").cloned().unwrap_or(options)
}

fn session_response(auth: &Auth, db: &Database, body: Value, status: u16) -> Result<HttpResponse, Error> {
    let token = insert_session(db)?;
    Ok(HttpResponse::json(body, status).with_header(
        "set-cookie",
        session_cookie_header(&token, auth.cookie_secure()),
    ))
}

pub fn handle_auth(auth: &Auth, db: &Database, request: &HttpRequest) -> Result<Option<HttpResponse>, Error> {
    let path = request.path();
    let method = request.method.as_str();
    let cookie = HttpResponse::cookie(request, SESSION_COOKIE);

    if path == "/api/auth/status" && method == "GET" {
        if !auth.enabled() {
            return Ok(Some(HttpResponse::json(json!({ "enrolled": true, "session": true }), 200)));
        }
        return Ok(Some(HttpResponse::json(
            json!({
                "enrolled": enrolled(db)?,
                "session": valid_session(db, cookie.as_deref())?,
            }),
            200,
        )));
    }

    if !auth.enabled() {
        return Ok(None);
    }

    if path == "/api/internal/passkey-reset" && method == "POST" {
        let presented = request
            .header("x-pods-reset-key")
            .ok_or_else(|| Error::Unauthorized("reset key is required".into()))?;
        if !auth.reset_key_matches(presented) {
            return Err(Error::Unauthorized("reset key is invalid".into()));
        }
        {
            let conn = db.lock()?;
            conn.execute_batch(
                "DELETE FROM passkey_credentials;
                 DELETE FROM auth_sessions;
                 DELETE FROM auth_enroll_tokens;
                 DELETE FROM auth_webauthn_state;",
            )?;
        }
        let enroll = Uuid::new_v4().to_string();
        let now = db::now_unix();
        db.execute(
            "INSERT INTO auth_enroll_tokens (token_hash, expires_at, used) VALUES (?, ?, 0)",
            rusqlite::params![hash_secret(&enroll), now + ENROLL_TTL_SECS],
        )?;
        let enroll_url = format!("{}/#enroll={enroll}", auth.origin());
        return Ok(Some(HttpResponse::json(json!({ "enroll_url": enroll_url }), 200)));
    }

    if path == "/api/auth/logout" && method == "POST" {
        if let Some(token) = cookie {
            let _ = db.execute(
                "DELETE FROM auth_sessions WHERE token_hash = ?",
                rusqlite::params![hash_secret(&token)],
            );
        }
        return Ok(Some(
            HttpResponse::no_content().with_header("set-cookie", clear_session_cookie(auth.cookie_secure())),
        ));
    }

    if path == "/api/auth/register/options" && method == "POST" {
        let body = request.json_object()?;
        let enroll = body
            .get("token")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Unauthorized("enroll token is required".into()))?;
        enroll_token_valid(db, enroll)?;
        let existing = list_passkeys(db)?;
        let ids: Vec<String> = existing.iter().map(|c| c.credential_id.clone()).collect();
        let (options, state) = auth.engine().start_registration(&ids)?;
        let state_id = put_webauthn_state(db, "register", &state, Some(enroll))?;
        return Ok(Some(HttpResponse::json(
            json!({ "state_id": state_id, "publicKey": webauthn_public_key(options) }),
            200,
        )));
    }

    if path == "/api/auth/register" && method == "POST" {
        let body = request.json_object()?;
        let state_id = body
            .get("state_id")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Invalid("state_id is required".into()))?;
        let credential = body
            .get("credential")
            .cloned()
            .ok_or_else(|| Error::Invalid("credential is required".into()))?;
        let wrapped = take_webauthn_state(db, state_id, "register")?;
        let enroll = wrapped
            .get("enroll_token")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Unauthorized("enroll token is invalid".into()))?;
        consume_enroll_token(db, enroll)?;
        let state = wrapped.get("state").cloned().unwrap_or(Value::Null);
        let stored = auth.engine().finish_registration(&state, &credential)?;
        let now = db::now_unix();
        db.execute(
            "INSERT INTO passkey_credentials (credential_id, user_handle, public_key_json, counter, created_at) VALUES (?, ?, ?, 0, ?)",
            rusqlite::params![stored.credential_id, USER_HANDLE, stored.public_key_json, now],
        )?;
        return Ok(Some(session_response(auth, db, json!({ "enrolled": true, "session": true }), 201)?));
    }

    if path == "/api/auth/login/options" && method == "POST" {
        let credentials = list_passkeys(db)?;
        let (options, state) = auth.engine().start_authentication(&credentials)?;
        let state_id = put_webauthn_state(db, "login", &state, None)?;
        return Ok(Some(HttpResponse::json(
            json!({ "state_id": state_id, "publicKey": webauthn_public_key(options) }),
            200,
        )));
    }

    if path == "/api/auth/login" && method == "POST" {
        let body = request.json_object()?;
        let state_id = body
            .get("state_id")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::Invalid("state_id is required".into()))?;
        let credential = body
            .get("credential")
            .cloned()
            .ok_or_else(|| Error::Invalid("credential is required".into()))?;
        let wrapped = take_webauthn_state(db, state_id, "login")?;
        let state = wrapped.get("state").cloned().unwrap_or(Value::Null);
        let credential_id = auth.engine().finish_authentication(&state, &credential)?;
        let exists = db.scalar_i64(
            "SELECT 1 FROM passkey_credentials WHERE credential_id = ?",
            rusqlite::params![credential_id],
        )?;
        if exists.is_none() {
            return Err(Error::Unauthorized("passkey assertion is invalid".into()));
        }
        return Ok(Some(session_response(auth, db, json!({ "enrolled": true, "session": true }), 200)?));
    }

    Ok(None)
}
