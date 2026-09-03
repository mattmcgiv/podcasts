use crate::backend::{Backend, DisabledDirectory};
use crate::db::Database;
use crate::feeds::UreqFetcher;
use crate::http::HttpRequest;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;

pub struct Handle {
    backend: Backend,
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
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
    let Ok(db) = Database::open(&PathBuf::from(path)) else {
        return ptr::null_mut();
    };
    let backend = Backend::new(db, Arc::new(UreqFetcher::default()), Arc::new(DisabledDirectory));
    Box::into_raw(Box::new(Handle { backend }))
}

#[no_mangle]
pub extern "C" fn pods_backend_close(handle: *mut Handle) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)) };
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
