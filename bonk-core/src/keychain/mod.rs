//! Keychain abstraction - Security.framework on mac, Credential Manager on Win, Secret Service on Linux
//! Single trait, OS-specific impl at compile time.

use crate::error::{CoreError, CoreResult};

pub trait CredentialStore: Send + Sync {
    fn get(&self, key: &str) -> CoreResult<Option<String>>;
    fn set(&self, key: &str, value: &str) -> CoreResult<()>;
    fn delete(&self, key: &str) -> CoreResult<()>;
}

/// OS keychain (uses `keyring` crate) - enabled with `keychain-os` feature
#[cfg(feature = "keychain-os")]
pub struct OsCredentialStore {
    service: String,
}

#[cfg(feature = "keychain-os")]
impl OsCredentialStore {
    pub fn new(service: &str) -> Self {
        Self { service: service.into() }
    }
}

#[cfg(feature = "keychain-os")]
impl CredentialStore for OsCredentialStore {
    fn get(&self, key: &str) -> CoreResult<Option<String>> {
        let entry = keyring::Entry::new(&self.service, key).map_err(|e| CoreError::Keychain(e.to_string()))?;
        match entry.get_password() {
            Ok(v) => Ok(Some(v)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(CoreError::Keychain(e.to_string())),
        }
    }
    fn set(&self, key: &str, value: &str) -> CoreResult<()> {
        let entry = keyring::Entry::new(&self.service, key).map_err(|e| CoreError::Keychain(e.to_string()))?;
        entry.set_password(value).map_err(|e| CoreError::Keychain(e.to_string()))
    }
    fn delete(&self, key: &str) -> CoreResult<()> {
        let entry = keyring::Entry::new(&self.service, key).map_err(|e| CoreError::Keychain(e.to_string()))?;
        match entry.delete_credential() {
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(CoreError::Keychain(e.to_string())),
        }
    }
}

/// In-memory fallback (for tests / dev without OS keychain)
pub struct InMemoryCredentialStore {
    inner: std::sync::Mutex<std::collections::HashMap<String, String>>,
}

impl InMemoryCredentialStore {
    pub fn new() -> Self {
        Self { inner: std::sync::Mutex::new(Default::default()) }
    }
}

impl Default for InMemoryCredentialStore {
    fn default() -> Self { Self::new() }
}

impl CredentialStore for InMemoryCredentialStore {
    fn get(&self, key: &str) -> CoreResult<Option<String>> {
        Ok(self.inner.lock().unwrap().get(key).cloned())
    }
    fn set(&self, key: &str, value: &str) -> CoreResult<()> {
        self.inner.lock().unwrap().insert(key.into(), value.into());
        Ok(())
    }
    fn delete(&self, key: &str) -> CoreResult<()> {
        self.inner.lock().unwrap().remove(key);
        Ok(())
    }
}

/// Helper to build key names matching BonkMac's KeychainHelper
pub fn password_key(host_id: &uuid::Uuid) -> String {
    format!("bonk.host.{}.password", host_id)
}
pub fn private_key_key(host_id: &uuid::Uuid) -> String {
    format!("bonk.host.{}.privateKey", host_id)
}
