//! PTY abstraction - portable-pty on all platforms
//! On Windows uses ConPTY, on Unix uses forkpty. Same API.

use crate::error::{CoreError, CoreResult};
use portable_pty::{CommandBuilder, PtySize, NativePtySystem, PtySystem};
use std::io::{Read, Write};

/// Spawn a local shell PTY (for testing without SSH)
pub struct LocalPty {
    master: Box<dyn portable_pty::MasterPty + Send>,
    #[allow(dead_code)]
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

impl LocalPty {
    pub fn spawn(shell: &str, cols: u16, rows: u16) -> CoreResult<Self> {
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| CoreError::Pty(e.to_string()))?;

        let mut cmd = CommandBuilder::new(shell);
        // On Windows, `pwsh` or `cmd.exe`; on Unix, `$SHELL` or `bash`
        let mut child = pair.slave.spawn_command(cmd).map_err(|e| CoreError::Pty(e.to_string()))?;

        // Try to get reader/writer quickly to verify spawn
        drop(pair.slave);

        Ok(Self { master: pair.master, child })
    }

    pub fn resize(&self, cols: u16, rows: u16) -> CoreResult<()> {
        self.master.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| CoreError::Pty(e.to_string()))
    }

    pub fn try_clone_reader(&self) -> CoreResult<Box<dyn Read + Send>> {
        self.master.try_clone_reader().map_err(|e| CoreError::Pty(e.to_string()))
    }

    pub fn take_writer(&self) -> CoreResult<Box<dyn Write + Send>> {
        self.master.take_writer().map_err(|e| CoreError::Pty(e.to_string()))
    }
}
