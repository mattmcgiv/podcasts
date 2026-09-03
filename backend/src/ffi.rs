use crate::backend::Backend;
use crate::db::Database;
use crate::directory::PodcastIndexClient;
use crate::feeds::UreqFetcher;
use crate::http::HttpRequest;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;

pub struct Handle {
    backend: Arc<Backend>,
}

fn open_backend(path: PathBuf) -> Option<Handle> {
    let db = Database::open(&path).ok()?;
    let data_root = path.parent().map(|p| p.join("AdRemovalData"));
    let directory: Arc<dyn crate::backend::DirectorySearcher> = crate::directory::configured_directory();
    let backend = Backend::with_data_root(db, Arc::new(UreqFetcher::default()), directory, data_root);
    let backend = Arc::new(backend);
    backend.start_runtime();
    Some(Handle { backend })
}

#[no_mangle]
pub extern "C" fn pods_backend_prepare(live_path: *const c_char, seed_path: *const c_char) -> c_int {
    if live_path.is_null() {
        return 1;
    }
    let live = PathBuf::from(unsafe { CStr::from_ptr(live_path) }.to_string_lossy().into_owned());
    let seed = if seed_path.is_null() {
        None
    } else {
        Some(PathBuf::from(unsafe { CStr::from_ptr(seed_path) }.to_string_lossy().into_owned()))
    };
    match crate::bootstrap::prepare(&live, seed.as_deref()) {
        Ok(_) => 0,
        Err(_) => 1,
    }
}

#[no_mangle]
pub extern "C" fn pods_backend_open(path: *const c_char) -> *mut Handle {
    if path.is_null() {
        return ptr::null_mut();
    }
    let path = PathBuf::from(unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned());
    match open_backend(path) {
        Some(handle) => Box::into_raw(Box::new(handle)),
        None => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn pods_backend_configure(handle: *mut Handle, json: *const c_char) -> c_int {
    if handle.is_null() || json.is_null() {
        return 1;
    }
    let handle = unsafe { &*handle };
    let raw = unsafe { CStr::from_ptr(json) }.to_string_lossy();
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return 1;
    };
    let key = value.get("podcastindex_key").and_then(|v| v.as_str()).unwrap_or("").trim();
    let secret = value.get("podcastindex_secret").and_then(|v| v.as_str()).unwrap_or("").trim();
    let base = value
        .get("podcastindex_base_url")
        .and_then(|v| v.as_str())
        .unwrap_or("https://api.podcastindex.org/api/1.0");
    if key.is_empty() || secret.is_empty() {
        return 0;
    }
    handle
        .backend
        .set_directory(Arc::new(PodcastIndexClient::new(key, secret, base)));
    0
}

#[no_mangle]
pub extern "C" fn pods_backend_close(handle: *mut Handle) {
    if !handle.is_null() {
        unsafe {
            let boxed = Box::from_raw(handle);
            boxed.backend.stop_runtime();
        }
    }
}

#[no_mangle]
pub extern "C" fn pods_backend_handle(
    handle: *mut Handle,
    method: *const c_char,
    target: *const c_char,
    headers: *const c_char,
    body: *const u8,
    body_len: usize,
    out_status: *mut c_int,
    out_len: *mut usize,
) -> *mut u8 {
    if handle.is_null() || method.is_null() || target.is_null() {
        return ptr::null_mut();
    }
    let handle = unsafe { &*handle };
    let method = unsafe { CStr::from_ptr(method) }.to_string_lossy().into_owned();
    let target = unsafe { CStr::from_ptr(target) }.to_string_lossy().into_owned();
    let mut request = HttpRequest::new(method, target);
    if !headers.is_null() {
        let raw = unsafe { CStr::from_ptr(headers) }.to_string_lossy();
        for line in raw.lines() {
            if let Some((k, v)) = line.split_once(':') {
                request.headers.insert(k.trim().to_lowercase(), v.trim().to_string());
            }
        }
    }
    if !body.is_null() && body_len > 0 {
        request.body = unsafe { std::slice::from_raw_parts(body, body_len) }.to_vec();
    }
    let response = handle.backend.handle(request);
    if !out_status.is_null() {
        unsafe { *out_status = response.status_code as c_int };
    }
    let mut out = Vec::new();
    for (k, v) in &response.headers {
        out.extend_from_slice(format!("{k}: {v}\n").as_bytes());
    }
    out.extend_from_slice(b"\n");
    out.extend_from_slice(&response.body);
    if !out_len.is_null() {
        unsafe { *out_len = out.len() };
    }
    let ptr = out.as_mut_ptr();
    std::mem::forget(out);
    ptr
}

#[no_mangle]
pub extern "C" fn pods_backend_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe { drop(Vec::from_raw_parts(ptr, len, len)) };
}

#[allow(dead_code)]
fn _keep_cstring() {
    let _ = CString::new("x");
}
