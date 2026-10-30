//! SYSTEM/session fixture, only in the standalone test executable on a disposable runner.
use super::*;
use windows::core::PWSTR;
use windows::Win32::{
    Foundation::{CloseHandle, HANDLE, LUID},
    Security::{
        AdjustTokenPrivileges, DuplicateTokenEx, LookupPrivilegeValueW, SecurityImpersonation,
        SetTokenInformation, TokenPrimary, TokenSessionId, LUID_AND_ATTRIBUTES,
        SE_PRIVILEGE_ENABLED, SE_TCB_NAME, TOKEN_ALL_ACCESS, TOKEN_PRIVILEGES,
    },
    System::{
        RemoteDesktop::WTSGetActiveConsoleSessionId,
        Threading::{
            CreateProcessAsUserW, GetCurrentProcess, GetCurrentProcessId, OpenProcessToken,
            WaitForSingleObject, CREATE_NO_WINDOW, INFINITE, PROCESS_INFORMATION, STARTUPINFOW,
        },
    },
};

pub fn relay() {
    assert!(Command::new("whoami")
        .arg("/user")
        .output()
        .unwrap()
        .stdout
        .windows(8)
        .any(|v| v == b"S-1-5-18"));
    let session: u32 = std::env::args().nth(2).unwrap().parse().unwrap();
    let port = std::env::args().nth(3).unwrap();
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &mut token).unwrap();
        // No production privilege changes. This fixture needs TCB to place its
        // own disposable SYSTEM child into the same desktop session as a Host.
        let mut luid = LUID::default();
        LookupPrivilegeValueW(PCWSTR::null(), SE_TCB_NAME, &mut luid).unwrap();
        let privileges = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            Privileges: [LUID_AND_ATTRIBUTES {
                Luid: luid,
                Attributes: SE_PRIVILEGE_ENABLED,
            }],
        };
        AdjustTokenPrivileges(token, false, Some(&privileges), 0, None, None).unwrap();
        let mut primary = HANDLE::default();
        DuplicateTokenEx(
            token,
            TOKEN_ALL_ACCESS,
            None,
            SecurityImpersonation,
            TokenPrimary,
            &mut primary,
        )
        .unwrap();
        SetTokenInformation(primary, TokenSessionId, (&session as *const u32).cast(), 4).unwrap();
        let mut startup = STARTUPINFOW::default();
        startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        let mut desktop: Vec<u16> = "winsta0\\default".encode_utf16().chain(Some(0)).collect();
        startup.lpDesktop = PWSTR(desktop.as_mut_ptr());
        let exe = std::env::current_exe().unwrap();
        let mut command: Vec<u16> = format!("\"{}\" --system-owner {port}", exe.display())
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let mut process = PROCESS_INFORMATION::default();
        CreateProcessAsUserW(
            Some(primary),
            PCWSTR::null(),
            Some(PWSTR(command.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_NO_WINDOW,
            None,
            PCWSTR::null(),
            &startup,
            &mut process,
        )
        .unwrap();
        CloseHandle(token).unwrap();
        CloseHandle(primary).unwrap();
        CloseHandle(process.hThread).unwrap();
        WaitForSingleObject(process.hProcess, INFINITE);
        CloseHandle(process.hProcess).unwrap();
    }
}
pub fn owner() {
    assert!(Command::new("whoami")
        .arg("/user")
        .output()
        .unwrap()
        .stdout
        .windows(8)
        .any(|v| v == b"S-1-5-18"));
    let port: u16 = std::env::args().nth(2).unwrap().parse().unwrap();
    let stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    super::owner(std::io::BufReader::new(stream.try_clone().unwrap()), stream);
}
pub unsafe fn validate(
    desktop: &IDesktopWallpaper,
    baseline: &(Vec<(String, String)>, i32, u32),
    wrapper: Option<&std::path::Path>,
) {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();
    let session = WTSGetActiveConsoleSessionId();
    let name = format!("G3-Wallpaper-Disposable-{}", GetCurrentProcessId());
    let exe = std::env::current_exe()
        .unwrap()
        .to_string_lossy()
        .replace("'", "''");
    let script = format!("$a=New-ScheduledTaskAction -Execute '{exe}' -Argument '--system-relay {session} {port}'; $p=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount; Register-ScheduledTask -TaskName '{name}' -Action $a -Principal $p | Out-Null; Start-ScheduledTask -TaskName '{name}'");
    assert!(Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .status()
        .unwrap()
        .success());
    let start = Instant::now();
    let stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(
                    start.elapsed() < Duration::from_secs(30),
                    "SYSTEM fixture failed to start in session {session}"
                );
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(error) => panic!("{error}"),
        }
    };
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .unwrap();
    let mut input = stream.try_clone().unwrap();
    let mut output = std::io::BufReader::new(stream);
    let mut send = |value: &str| {
        writeln!(input, "{value}").unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        assert_eq!(line.trim(), "accepted");
    };
    let start_command = wrapper
        .map(|path| format!("wrapper:{}", path.display()))
        .unwrap_or_else(|| "begin1".to_owned());
    send(&start_command);
    wait_state(desktop, false);
    send(if wrapper.is_some() {
        "wrapperend"
    } else {
        "end1"
    });
    wait_state(desktop, true);
    assert_eq!(&snapshot(desktop), baseline);
    send(&start_command);
    wait_state(desktop, false);
    drop(send);
    writeln!(input, "crash").unwrap();
    input.flush().unwrap();
    wait_state(desktop, true);
    assert_eq!(&snapshot(desktop), baseline);
    let script = format!("$t=Get-ScheduledTask -TaskName '{name}'; while($t.State -eq 'Running'){{Start-Sleep -Milliseconds 100; $t=Get-ScheduledTask -TaskName '{name}'}}; Unregister-ScheduledTask -TaskName '{name}' -Confirm:$false");
    assert!(Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .status()
        .unwrap()
        .success());
    println!("PASS SYSTEM Host context: user wallpaper restored after session end and server crash (session {session})");
}
