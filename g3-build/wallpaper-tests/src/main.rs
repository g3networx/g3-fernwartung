#[path = "../../../src/platform/g3_wallpaper.rs"]
mod wallpaper;
use std::{
    io::{BufRead, Write},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
use windows::{
    core::{Interface, PCWSTR, PWSTR},
    Win32::{
        Foundation::S_FALSE,
        System::Com::{
            CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_APARTMENTTHREADED,
        },
        UI::Shell::{DesktopWallpaper, IDesktopWallpaper},
    },
};

unsafe fn string(value: PWSTR) -> String {
    let result = value.to_string().unwrap();
    CoTaskMemFree(Some(value.0.cast()));
    result
}
unsafe fn snapshot(desktop: &IDesktopWallpaper) -> (Vec<(String, String)>, i32, u32) {
    let mut pictures = Vec::new();
    for index in 0..desktop.GetMonitorDevicePathCount().unwrap() {
        let monitor = desktop.GetMonitorDevicePathAt(index).unwrap();
        let image = string(desktop.GetWallpaper(PCWSTR(monitor.0)).unwrap());
        pictures.push((string(monitor), image));
    }
    (
        pictures,
        desktop.GetPosition().unwrap().0,
        desktop.GetBackgroundColor().unwrap().0,
    )
}
unsafe fn enabled(desktop: &IDesktopWallpaper) -> bool {
    desktop.GetStatus().unwrap().0 & 1 != 0
}
unsafe fn wait_state(desktop: &IDesktopWallpaper, expected: bool) {
    let start = Instant::now();
    while enabled(desktop) != expected {
        assert!(
            start.elapsed() < Duration::from_secs(15),
            "Wallpaper did not become {expected}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}
fn owner() {
    for line in std::io::stdin().lock().lines() {
        match line.unwrap().as_str() {
            "begin1" => wallpaper::begin(1),
            "begin2" => wallpaper::begin(2),
            "end1" => wallpaper::end(1),
            "end2" => wallpaper::end(2),
            "crash" => std::process::exit(23), // Bypass all destructors, no forced termination.
            "quit" => return,
            _ => panic!("unknown test command"),
        }
        println!("accepted");
        std::io::stdout().flush().unwrap();
    }
}
unsafe fn validate() {
    assert_eq!(
        std::env::var("G3_WALLPAPER_TEST_DISPOSABLE").as_deref(),
        Ok("YES")
    );
    assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
    CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok().unwrap();
    let desktop: IDesktopWallpaper = CoCreateInstance(&DesktopWallpaper, None, CLSCTX_ALL).unwrap();
    let count = desktop.GetMonitorDevicePathCount().unwrap();
    assert!(
        count > 0,
        "No interactive test desktop; test must not be counted as passed"
    );
    // Install a fixture only on the disposable runner. Production code never calls SetWallpaper.
    let path = std::env::current_dir().unwrap().join("fixture.bmp");
    let mut bmp = vec![0u8; 70];
    bmp[0..2].copy_from_slice(b"BM");
    bmp[2..6].copy_from_slice(&70u32.to_le_bytes());
    bmp[10..14].copy_from_slice(&54u32.to_le_bytes());
    bmp[14..18].copy_from_slice(&40u32.to_le_bytes());
    bmp[18..22].copy_from_slice(&2u32.to_le_bytes());
    bmp[22..26].copy_from_slice(&2u32.to_le_bytes());
    bmp[26..28].copy_from_slice(&1u16.to_le_bytes());
    bmp[28..30].copy_from_slice(&24u16.to_le_bytes());
    bmp[54..].fill(190);
    std::fs::write(&path, bmp).unwrap();
    let wide: Vec<u16> = path
        .to_str()
        .unwrap()
        .encode_utf16()
        .chain(Some(0))
        .collect();
    desktop
        .SetWallpaper(PCWSTR::null(), PCWSTR(wide.as_ptr()))
        .unwrap();
    desktop.Enable(true).unwrap();
    wait_state(&desktop, true);
    let expected_image = path.to_string_lossy().to_lowercase();
    let fixture_start = Instant::now();
    while !snapshot(&desktop)
        .0
        .iter()
        .all(|(_, image)| image.to_lowercase() == expected_image)
    {
        assert!(
            fixture_start.elapsed() < Duration::from_secs(15),
            "Fixture did not become active"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    let baseline = snapshot(&desktop);
    assert!(baseline.0.iter().all(|(_, image)| !image.is_empty()));
    let mut child = Command::new(std::env::current_exe().unwrap())
        .arg("--owner")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = std::io::BufReader::new(child.stdout.take().unwrap());
    let mut send = |value: &str| {
        writeln!(input, "{value}").unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        assert_eq!(line.trim(), "accepted");
    };
    send("begin1");
    wait_state(&desktop, false);
    assert_eq!(
        snapshot(&desktop).1,
        baseline.1,
        "Hiding changed picture positioning"
    );
    send("begin2");
    send("end1");
    std::thread::sleep(Duration::from_millis(400));
    assert!(
        !enabled(&desktop),
        "First disconnect restored while second session remained"
    );
    send("end2");
    wait_state(&desktop, true);
    assert_eq!(snapshot(&desktop), baseline);
    println!("PASS normal last-session cleanup and overlapping sessions");
    for _ in 0..5 {
        send("begin1");
        wait_state(&desktop, false);
        send("end1");
        wait_state(&desktop, true);
        assert_eq!(snapshot(&desktop), baseline);
    }
    println!("PASS five reconnect/disconnect cycles");
    desktop.Enable(false).unwrap();
    send("begin1");
    std::thread::sleep(Duration::from_millis(400));
    send("end1");
    std::thread::sleep(Duration::from_millis(700));
    assert!(!enabled(&desktop));
    assert_eq!(snapshot(&desktop), baseline);
    assert_eq!(
        (desktop.vtable().Enable)(desktop.as_raw(), false.into()),
        S_FALSE
    );
    println!("PASS already-disabled background stays disabled");
    desktop.Enable(true).unwrap();
    send("begin1");
    wait_state(&desktop, false);
    drop(send);
    writeln!(input, "crash").unwrap();
    input.flush().unwrap();
    assert_eq!(child.wait().unwrap().code(), Some(23));
    wait_state(&desktop, true);
    assert_eq!(snapshot(&desktop), baseline);
    println!("PASS abrupt owner-process exit without Drop restores original configuration");
    assert!(wallpaper::supported_client("g3Host"));
    assert!(wallpaper::supported_client("g3Fernwartung"));
    assert!(!wallpaper::supported_client("RustDesk"));
    println!("PASS client scope; monitor count={count}");
}
fn main() {
    match std::env::args().nth(1).as_deref() {
        Some(wallpaper::HELPER_ARG) => {
            if let Err(error) = wallpaper::run_helper() {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        Some("--owner") => owner(),
        Some("--validate") => unsafe {
            validate();
        },
        _ => panic!("Explicit validation mode required"),
    }
}
