use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("SSH error: {0}")]
    Ssh(String),

    #[error("SFTP error: {0}")]
    Sftp(String),

    #[error("PTY error: {0}")]
    Pty(String),

    #[error("Storage error: {0}")]
    Storage(String),

    #[error("Keychain error: {0}")]
    Keychain(String),

    #[error("AI error: {0}")]
    Ai(String),

    #[error("Not connected")]
    NotConnected,

    #[error("Cancelled")]
    Cancelled,

    #[error("Invalid argument: {0}")]
    InvalidArgument(String),

    #[error("IO error: {0}")]
    Io(String),

    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

pub type CoreResult<T> = Result<T, CoreError>;

/// FFI-friendly error code (mirrors CoreError for C/Swift)
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreErrorCode {
    Ok = 0,
    Ssh = 1,
    Sftp = 2,
    Pty = 3,
    Storage = 4,
    Keychain = 5,
    Ai = 6,
    NotConnected = 7,
    Cancelled = 8,
    InvalidArgument = 9,
    Io = 10,
    Unknown = 99,
}

impl From<&CoreError> for CoreErrorCode {
    fn from(e: &CoreError) -> Self {
        match e {
            CoreError::Ssh(_) => Self::Ssh,
            CoreError::Sftp(_) => Self::Sftp,
            CoreError::Pty(_) => Self::Pty,
            CoreError::Storage(_) => Self::Storage,
            CoreError::Keychain(_) => Self::Keychain,
            CoreError::Ai(_) => Self::Ai,
            CoreError::NotConnected => Self::NotConnected,
            CoreError::Cancelled => Self::Cancelled,
            CoreError::InvalidArgument(_) => Self::InvalidArgument,
            CoreError::Io(_) => Self::Io,
            CoreError::Other(_) => Self::Unknown,
        }
    }
}
