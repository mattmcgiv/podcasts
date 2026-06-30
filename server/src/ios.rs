use crate::{api, build_state, db, feeds, Config};
use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::mpsc;

pub struct PodsIosRuntime {
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

/// Start the Pods server on-device.
///
/// All pointer arguments must be valid UTF-8 C strings. Returns null if the
/// runtime cannot be created or if startup fails before the listener is bound.
/// The caller owns the returned pointer and must pass it to `pods_ios_stop`.
#[no_mangle]
pub extern "C" fn pods_ios_start(
    database_path: *const c_char,
    bind_addr: *const c_char,
    podcastindex_key: *const c_char,
    podcastindex_secret: *const c_char,
    podcastindex_base: *const c_char,
) -> *mut PodsIosRuntime {
    let Some(database_path) = c_str(database_path) else {
        return std::ptr::null_mut();
    };
    let Some(bind_addr) = c_str(bind_addr) else {
        return std::ptr::null_mut();
    };
    let Some(podcastindex_key) = c_str(podcastindex_key) else {
        return std::ptr::null_mut();
    };
    let Some(podcastindex_secret) = c_str(podcastindex_secret) else {
        return std::ptr::null_mut();
    };
    let Some(podcastindex_base) = c_str(podcastindex_base) else {
        return std::ptr::null_mut();
    };

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();

    let thread = std::thread::spawn(move || {
        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        {
            Ok(runtime) => runtime,
            Err(err) => {
                let _ = ready_tx.send(Err(err.to_string()));
                return;
            }
        };

        runtime.block_on(async move {
            let pool = match db::init(&database_path).await {
                Ok(pool) => pool,
                Err(err) => {
                    let _ = ready_tx.send(Err(err.to_string()));
                    return;
                }
            };
            let cfg = Config {
                pi_key: podcastindex_key,
                pi_secret: podcastindex_secret,
                pi_base: if podcastindex_base.is_empty() {
                    "https://api.podcastindex.org/api/1.0".to_string()
                } else {
                    podcastindex_base
                },
                db_path: database_path,
                bind_addr: bind_addr.clone(),
            };
            let state = build_state(pool, cfg);

            let refresher = state.clone();
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_secs(900)).await;
                    let (ok, errs) = feeds::refresh_all(&refresher).await;
                    tracing::info!(ok, errs, "ios feed refresh pass");
                }
            });

            let listener = match tokio::net::TcpListener::bind(&bind_addr).await {
                Ok(listener) => listener,
                Err(err) => {
                    let _ = ready_tx.send(Err(err.to_string()));
                    return;
                }
            };
            let _ = ready_tx.send(Ok(()));

            if let Err(err) = axum::serve(listener, api::router(state))
                .with_graceful_shutdown(async {
                    let _ = shutdown_rx.await;
                })
                .await
            {
                tracing::error!(error = %err, "ios server stopped with error");
            }
        });
    });

    match ready_rx.recv_timeout(std::time::Duration::from_secs(10)) {
        Ok(Ok(())) => Box::into_raw(Box::new(PodsIosRuntime {
            shutdown: Some(shutdown_tx),
            thread: Some(thread),
        })),
        _ => {
            let _ = shutdown_tx.send(());
            let _ = thread.join();
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn pods_ios_stop(handle: *mut PodsIosRuntime) {
    if handle.is_null() {
        return;
    }
    let mut handle = unsafe { Box::from_raw(handle) };
    if let Some(shutdown) = handle.shutdown.take() {
        let _ = shutdown.send(());
    }
    if let Some(thread) = handle.thread.take() {
        let _ = thread.join();
    }
}

fn c_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(ToOwned::to_owned)
}
