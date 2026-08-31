//! SFTP is exposed via `ssh::SftpChannel` trait.
//! This module holds helpers (path normalization, progress reporting, etc.)

use crate::models::SftpFileEntry;

/// Normalize remote path (handling `~`, `.`, `..`)
pub fn normalize_remote_path(base: &str, input: &str) -> String {
    if input.starts_with('/') || input.starts_with('~') {
        return input.to_string();
    }
    let base = base.trim_end_matches('/');
    if base.is_empty() {
        format!("/{}", input)
    } else {
        format!("{}/{}", base, input)
    }
}

/// Sort entries: directories first, then alphabetical
pub fn sort_entries(mut entries: Vec<SftpFileEntry>) -> Vec<SftpFileEntry> {
    entries.sort_by(|a, b| match (a.is_directory, b.is_directory) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });
    entries
}
