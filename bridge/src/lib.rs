//! C ABI bridge for the Anki Rust backend (rslib).
//!
//! Four functions, modelled on AnkiDroid's JNI bridge and amgi's iOS bridge:
//! open a backend, run a protobuf RPC, free the response, close the backend.
//! Everything else (scheduling, import/export, rendering, stats) lives inside
//! rslib and is reached through `anki_run_method`.

use std::os::raw::c_int;
use std::slice;

use anki::backend::{init_backend, Backend};
use prost::Message;

/// Create a new Anki backend instance.
///
/// # Safety
/// - `init_data` must point to `init_len` readable bytes containing a
///   serialized `anki.backend.BackendInit` message, or be null for defaults.
/// - `out_ptr` must point to writable memory for one `i64`.
///
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub unsafe extern "C" fn anki_open_backend(
    init_data: *const u8,
    init_len: usize,
    out_ptr: *mut i64,
) -> c_int {
    if out_ptr.is_null() {
        return -1;
    }
    let init_bytes: &[u8] = if init_data.is_null() || init_len == 0 {
        &[]
    } else {
        slice::from_raw_parts(init_data, init_len)
    };
    let default_bytes;
    let bytes_to_use: &[u8] = if init_bytes.is_empty() {
        default_bytes = anki_proto::backend::BackendInit::default().encode_to_vec();
        &default_bytes
    } else {
        init_bytes
    };

    match init_backend(bytes_to_use) {
        Ok(backend) => {
            *out_ptr = Box::into_raw(Box::new(backend)) as i64;
            0
        }
        Err(_) => -1,
    }
}

/// Execute a backend RPC method.
///
/// `service` / `method` are the integer indices rslib uses in its generated
/// `run_service_method` dispatch table (see tools/dispatch-gen).
///
/// # Safety
/// - `backend_ptr` must come from `anki_open_backend` and not be closed yet.
/// - `input_data`/`input_len` must describe readable protobuf bytes (or be null/0).
/// - `out_data`/`out_len` must be writable; the returned buffer must be released
///   with `anki_free_response`.
///
/// Returns 0 on success (response protobuf in `out_data`),
///         1 on backend error (`anki.backend.BackendError` protobuf in `out_data`),
///        -1 on FFI misuse.
#[no_mangle]
pub unsafe extern "C" fn anki_run_method(
    backend_ptr: i64,
    service: u32,
    method: u32,
    input_data: *const u8,
    input_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    if backend_ptr == 0 || out_data.is_null() || out_len.is_null() {
        return -1;
    }
    let backend = &*(backend_ptr as *const Backend);
    let input: &[u8] = if input_data.is_null() || input_len == 0 {
        &[]
    } else {
        slice::from_raw_parts(input_data, input_len)
    };

    match backend.run_service_method(service, method, input) {
        Ok(output) => {
            set_output(output, out_data, out_len);
            0
        }
        Err(err_bytes) => {
            set_output(err_bytes, out_data, out_len);
            1
        }
    }
}

/// Free a response buffer allocated by `anki_run_method`.
///
/// # Safety
/// `data`/`len` must be exactly what `anki_run_method` returned (or null/0).
#[no_mangle]
pub unsafe extern "C" fn anki_free_response(data: *mut u8, len: usize) {
    if !data.is_null() && len > 0 {
        drop(Vec::from_raw_parts(data, len, len));
    }
}

/// Close and destroy the backend instance.
///
/// # Safety
/// `backend_ptr` must come from `anki_open_backend` and must not be used again.
#[no_mangle]
pub unsafe extern "C" fn anki_close_backend(backend_ptr: i64) {
    if backend_ptr != 0 {
        drop(Box::from_raw(backend_ptr as *mut Backend));
    }
}

/// Returns a static, NUL-terminated string describing the bridge/anki build.
#[no_mangle]
pub extern "C" fn anki_bridge_version() -> *const std::os::raw::c_char {
    static VERSION: &[u8] = concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes();
    VERSION.as_ptr() as *const std::os::raw::c_char
}

unsafe fn set_output(data: Vec<u8>, out_data: *mut *mut u8, out_len: *mut usize) {
    let len = data.len();
    if len == 0 {
        *out_data = std::ptr::null_mut();
        *out_len = 0;
        return;
    }
    let mut boxed = data.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    *out_data = ptr;
    *out_len = len;
}
