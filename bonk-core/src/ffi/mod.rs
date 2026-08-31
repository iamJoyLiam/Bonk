//! C ABI for Swift (mac) and any other FFI consumer
//! Keep this minimal and stable - add new funcs, never change signatures.
//!
//! Swift side: see `bonk-mac-ffi/Sources/BonkCoreFFI/BonkCore.swift`

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::error::CoreErrorCode;
use crate::models::{HostItemDto, SshConnectionConfig};

/// Returns bonk-core version string. Caller must NOT free.
#[no_mangle]
pub extern "C" fn bonk_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// Initialize core (tracing). Safe to call multiple times.
#[no_mangle]
pub extern "C" fn bonk_core_init() -> CoreErrorCode {
    crate::init();
    CoreErrorCode::Ok
}

// ---------------------------------------------------------------------------
// Host store helpers (JSON over FFI - simplest stable ABI)
// The JSON schema is HostItemDto. Swift side encodes/decodes with Codable.
// ---------------------------------------------------------------------------

/// Validate HostItemDto JSON. Returns Ok if valid.
#[no_mangle]
pub extern "C" fn bonk_core_validate_host_json(json: *const c_char) -> CoreErrorCode {
    if json.is_null() {
        return CoreErrorCode::InvalidArgument;
    }
    let s = unsafe { CStr::from_ptr(json).to_string_lossy() };
    match serde_json::from_str::<HostItemDto>(&s) {
        Ok(_) => CoreErrorCode::Ok,
        Err(_) => CoreErrorCode::InvalidArgument,
    }
}

/// Example: connect test (async via callback)
///
/// In real FFI we need a task runtime handle. For scaffold we expose sync mock.
/// Real impl will use `tokio::Runtime` + callback id pattern like:
/// `bonk_core_ssh_connect(json_config, callback_id, on_connected, on_data, on_error)`
// ---------------------------------------------------------------------------

/// Free a string previously returned by bonk-core (if we ever return owned strings)
#[no_mangle]
pub extern "C" fn bonk_core_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

#[allow(dead_code)]
fn json_to_config(json: *const c_char) -> Result<SshConnectionConfig, CoreErrorCode> {
    if json.is_null() {
        return Err(CoreErrorCode::InvalidArgument);
    }
    let s = unsafe { CStr::from_ptr(json).to_string_lossy() };
    serde_json::from_str(&s).map_err(|_| CoreErrorCode::InvalidArgument)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn validate_host_json_ok() {
        let json = r#"{"id":"550e8400-e29b-41d4-a716-446655440000","name":"test","host":"1.2.3.4","port":22,"username":"root","authType":"password","groupId":null,"credentialId":null,"jumpHostId":null,"createdAt":"2026-01-01T00:00:00Z","lastConnectedAt":null,"sortOrder":0,"isFavorite":false,"isSerial":false,"serialBaudRate":null,"forceCompatibility":false}"#;
        let c = CString::new(json).unwrap();
        assert_eq!(bonk_core_validate_host_json(c.as_ptr()), CoreErrorCode::Ok);
    }
}
