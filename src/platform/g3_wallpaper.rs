//! Session-only wallpaper suppression. The helper owns the Windows change; an
//! inherited pipe restores it even when the server exits without running Drop.
use std::{
    collections::HashSet,
    io::{self, Read},
    os::windows::process::CommandExt,
    process::{Child, ChildStdin, Command, Stdio},
    sync::{mpsc, OnceLock},
};
use windows::{
    core::{w, Interface},
    Win32::{
        Foundation::{CloseHandle, HANDLE, S_FALSE, WAIT_OBJECT_0},
        System::{
            Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_APARTMENTTHREADED},
            Threading::{CreateMutexW, ReleaseMutex, WaitForSingleObject, CREATE_NO_WINDOW, INFINITE},
        },
        UI::Shell::{DesktopWallpaper, IDesktopWallpaper},
    },
};

pub const HELPER_ARG: &str = "--g3-wallpaper-guard";

pub fn supported_client(name: &str) -> bool {
    matches!(name, "g3Host" | "g3Fernwartung")
}

enum Event { Begin(i32), End(i32) }
static EVENTS: OnceLock<mpsc::Sender<Event>> = OnceLock::new();

struct Lease { input: Option<ChildStdin>, child: Child }
impl Lease {
    fn start() -> io::Result<Self> {
        let mut child = Command::new(std::env::current_exe()?)
            .arg(HELPER_ARG).stdin(Stdio::piped()).stdout(Stdio::null())
            .stderr(Stdio::inherit()).creation_flags(CREATE_NO_WINDOW.0).spawn()?;
        Ok(Self { input: child.stdin.take(), child })
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.input.take();
        // Keep hide/restore serialized, including immediate reconnects. Waiting
        // happens on our dedicated worker, never on the network runtime.
        if let Err(error) = self.child.wait() { eprintln!("Wallpaper helper wait failed: {error}"); }
    }
}

fn events() -> &'static mpsc::Sender<Event> {
    EVENTS.get_or_init(|| {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut connections = HashSet::new();
            let mut lease = None;
            for event in rx {
                match event {
                    Event::Begin(id) => {
                        if connections.insert(id) && lease.is_none() {
                            match Lease::start() {
                                Ok(value) => lease = Some(value),
                                Err(error) => eprintln!("Wallpaper helper could not start: {error}"),
                            }
                        }
                    }
                    Event::End(id) => {
                        connections.remove(&id);
                        if connections.is_empty() { lease.take(); }
                    }
                }
            }
        });
        tx
    })
}

pub fn begin(id: i32) {
    if let Err(error) = events().send(Event::Begin(id)) { eprintln!("Wallpaper begin failed: {error}"); }
}
pub fn end(id: i32) {
    if let Some(tx) = EVENTS.get() {
        if let Err(error) = tx.send(Event::End(id)) { eprintln!("Wallpaper end failed: {error}"); }
    }
}

struct SessionMutex(HANDLE);
impl Drop for SessionMutex {
    fn drop(&mut self) {
        unsafe {
            if let Err(error) = ReleaseMutex(self.0) { eprintln!("Wallpaper mutex release failed: {error}"); }
            if let Err(error) = CloseHandle(self.0) { eprintln!("Wallpaper mutex close failed: {error}"); }
        }
    }
}

/// Runs before normal client/service initialization, without reading profiles.
pub fn run_helper() -> Result<(), Box<dyn std::error::Error>> {
    unsafe {
        let handle = CreateMutexW(None, false, w!("Local\\OpsLinX.Wallpaper.Session"))?;
        let wait = WaitForSingleObject(handle, INFINITE);
        if wait != WAIT_OBJECT_0 && wait.0 != 0x80 {
            CloseHandle(handle)?;
            return Err("Wallpaper session mutex wait failed".into());
        }
        let _mutex = SessionMutex(handle);
        CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()?;
        let result = guard_desktop();
        CoUninitialize();
        result
    }
}

unsafe fn guard_desktop() -> Result<(), Box<dyn std::error::Error>> {
    let desktop: IDesktopWallpaper = CoCreateInstance(&DesktopWallpaper, None, CLSCTX_ALL)?;
    // Preserve S_FALSE: the high-level Result API discards whether wallpaper was
    // already disabled. Never enable a background that we did not disable.
    let changed = (desktop.vtable().Enable)(desktop.as_raw(), false.into());
    changed.ok()?;
    let mut buffer = [0u8; 64];
    let pipe_result = loop {
        match io::stdin().read(&mut buffer) {
            Ok(0) => break Ok(()),
            Ok(_) => continue,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => break Err(error),
        }
    };
    if changed != S_FALSE {
        // Enable keeps the original per-monitor pictures, positioning and
        // slideshow. SetWallpaper would replace that configuration with one file.
        let mut restored = desktop.Enable(true);
        for _ in 0..4 {
            if restored.is_ok() { break; }
            std::thread::sleep(std::time::Duration::from_millis(250));
            restored = desktop.Enable(true);
        }
        restored?;
    }
    pipe_result?;
    Ok(())
}
