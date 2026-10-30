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
            Com::{
                CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL,
                COINIT_APARTMENTTHREADED,
            },
            Threading::{
                CreateMutexW, ReleaseMutex, WaitForSingleObject, CREATE_NO_WINDOW, INFINITE,
            },
        },
        UI::Shell::{DesktopWallpaper, IDesktopWallpaper},
    },
};

pub const HELPER_ARG: &str = "--g3-wallpaper-guard";

pub fn supported_client(name: &str) -> bool {
    matches!(name, "g3Host" | "g3Fernwartung")
}

enum Event {
    Begin(i32),
    End(i32),
}
static EVENTS: OnceLock<mpsc::Sender<Event>> = OnceLock::new();

struct Lease {
    input: Option<ChildStdin>,
    child: Child,
}
impl Lease {
    fn start() -> io::Result<Self> {
        let mut child = Command::new(std::env::current_exe()?)
            .arg(HELPER_ARG)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .creation_flags(CREATE_NO_WINDOW.0)
            .spawn()?;
        Ok(Self {
            input: child.stdin.take(),
            child,
        })
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.input.take();
        // Keep hide/restore serialized, including immediate reconnects. Waiting
        // happens on our dedicated worker, never on the network runtime.
        match self.child.wait() {
            Ok(status) if !status.success() => eprintln!("Wallpaper helper failed: {status}"),
            Err(error) => eprintln!("Wallpaper helper wait failed: {error}"),
            _ => {}
        }
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
                                Err(error) => {
                                    eprintln!("Wallpaper helper could not start: {error}")
                                }
                            }
                        }
                    }
                    Event::End(id) => {
                        connections.remove(&id);
                        if connections.is_empty() {
                            lease.take();
                        }
                    }
                }
            }
        });
        tx
    })
}

pub fn begin(id: i32) {
    if let Err(error) = events().send(Event::Begin(id)) {
        eprintln!("Wallpaper begin failed: {error}");
    }
}
pub fn end(id: i32) {
    if let Some(tx) = EVENTS.get() {
        if let Err(error) = tx.send(Event::End(id)) {
            eprintln!("Wallpaper end failed: {error}");
        }
    }
}

struct SessionMutex(HANDLE);
impl Drop for SessionMutex {
    fn drop(&mut self) {
        unsafe {
            if let Err(error) = ReleaseMutex(self.0) {
                eprintln!("Wallpaper mutex release failed: {error}");
            }
            if let Err(error) = CloseHandle(self.0) {
                eprintln!("Wallpaper mutex close failed: {error}");
            }
        }
    }
}

/// Runs before normal client/service initialization, without reading profiles.
pub fn run_helper() -> Result<(), Box<dyn std::error::Error>> {
    if is_system()? {
        return run_user_helper();
    }
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

fn is_system() -> Result<bool, Box<dyn std::error::Error>> {
    use windows::Win32::{
        Security::{
            GetTokenInformation, IsWellKnownSid, TokenUser, WinLocalSystemSid, TOKEN_QUERY,
            TOKEN_USER,
        },
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    };
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token)?;
        let mut buffer = [0usize; 64];
        let mut size = 0;
        let result = GetTokenInformation(
            token,
            TokenUser,
            Some(buffer.as_mut_ptr().cast()),
            std::mem::size_of_val(&buffer) as u32,
            &mut size,
        );
        CloseHandle(token)?;
        result?;
        Ok(IsWellKnownSid(
            (*(buffer.as_ptr().cast::<TOKEN_USER>())).User.Sid,
            WinLocalSystemSid,
        )
        .as_bool())
    }
}

// Installed servers run as SYSTEM in the interactive session. COM must run as
// that session's user, otherwise it can address SYSTEM's wallpaper preferences.
fn run_user_helper() -> Result<(), Box<dyn std::error::Error>> {
    use windows::{
        core::{PCWSTR, PWSTR},
        Win32::{
            Foundation::{SetHandleInformation, HANDLE_FLAG_INHERIT},
            System::{
                Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE},
                RemoteDesktop::{ProcessIdToSessionId, WTSQueryUserToken},
                Threading::{
                    CreateProcessAsUserW, GetCurrentProcessId, GetExitCodeProcess,
                    PROCESS_INFORMATION, STARTF_USESTDHANDLES, STARTUPINFOW,
                },
            },
        },
    };
    unsafe {
        let mut session = 0;
        ProcessIdToSessionId(GetCurrentProcessId(), &mut session)?;
        let mut token = HANDLE::default();
        WTSQueryUserToken(session, &mut token)?;
        let input = GetStdHandle(STD_INPUT_HANDLE)?;
        SetHandleInformation(input, HANDLE_FLAG_INHERIT.0, HANDLE_FLAG_INHERIT)?;
        let mut startup = STARTUPINFOW::default();
        startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = input;
        startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE)?;
        startup.hStdError = GetStdHandle(STD_ERROR_HANDLE)?;
        let mut desktop: Vec<u16> = "winsta0\\default".encode_utf16().chain(Some(0)).collect();
        startup.lpDesktop = PWSTR(desktop.as_mut_ptr());
        let exe = std::env::current_exe()?;
        let mut command: Vec<u16> = format!("\"{}\" {}", exe.display(), HELPER_ARG)
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let mut process = PROCESS_INFORMATION::default();
        let created = CreateProcessAsUserW(
            Some(token),
            PCWSTR::null(),
            Some(PWSTR(command.as_mut_ptr())),
            None,
            None,
            true,
            CREATE_NO_WINDOW,
            None,
            PCWSTR::null(),
            &startup,
            &mut process,
        );
        CloseHandle(token)?;
        created?;
        CloseHandle(process.hThread)?;
        let waited = WaitForSingleObject(process.hProcess, INFINITE);
        let mut exit_code = 0;
        let exit_result = GetExitCodeProcess(process.hProcess, &mut exit_code);
        CloseHandle(process.hProcess)?;
        exit_result?;
        if exit_code != 0 {
            return Err(format!("User wallpaper helper failed: {exit_code}").into());
        }
        if waited != WAIT_OBJECT_0 {
            return Err("User wallpaper helper wait failed".into());
        }
        Ok(())
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
            if restored.is_ok() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
            restored = desktop.Enable(true);
        }
        restored?;
    }
    pipe_result?;
    Ok(())
}
