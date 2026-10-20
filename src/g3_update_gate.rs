//! A shared Windows byte-range lock covers the complete connection lifetime.
//! The installer takes the same range exclusively before touching any process.
use std::os::windows::{fs::OpenOptionsExt, io::AsRawHandle};
use std::{fs::File, io, path::Path};

pub const FILE_NAME: &str = "g3-update-session.lock";

#[repr(C)]
struct Overlapped {
    internal: usize,
    internal_high: usize,
    offset: u32,
    offset_high: u32,
    event: *mut std::ffi::c_void,
}

#[link(name = "kernel32")]
extern "system" {
    fn LockFileEx(
        handle: *mut std::ffi::c_void,
        flags: u32,
        reserved: u32,
        low: u32,
        high: u32,
        overlapped: *mut Overlapped,
    ) -> i32;
}

fn shared(path: &Path) -> io::Result<File> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .share_mode(3)
        .open(path)?;
    let mut overlapped: Overlapped = unsafe { std::mem::zeroed() };
    if unsafe { LockFileEx(file.as_raw_handle(), 1, 0, 1, 0, &mut overlapped) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

pub fn session() -> io::Result<Option<File>> {
    let path = std::env::current_exe()?.with_file_name(FILE_NAME);
    match shared(&path) {
        Ok(file) => Ok(Some(file)),
        // Portable clients have no installer or update gate. Their in-app
        // update never exits the process; the installer refuses live legacy apps.
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

pub fn watch_idle_process(args: &[String]) {
    if args.iter().any(|arg| {
        [
            "--service",
            "--server",
            "--version",
            "--build-date",
            "--install",
            "--uninstall",
        ]
        .contains(&arg.as_str())
    }) {
        return;
    }
    let path = match std::env::current_exe() {
        Ok(exe) => exe.with_file_name(FILE_NAME),
        Err(e) => {
            report("Update gate path", &e);
            return;
        }
    };
    if !path.is_file() {
        return;
    }
    std::thread::spawn(move || loop {
        match shared(&path) {
            // A successful exclusive installer lock proves that no session
            // in any process holds a shared lock. No process is force-killed.
            Err(e) if e.raw_os_error() == Some(33) => std::process::exit(0),
            Err(e) => {
                report("Update gate check", &e);
                return;
            }
            Ok(_) => {}
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    });
}

fn report(message: &str, error: &io::Error) {
    hbb_common::log::error!("{}: {}", message, error);
}
