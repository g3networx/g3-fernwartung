mod system_fixture;
#[path = "../../../src/platform/g3_wallpaper.rs"]
mod wallpaper;
use std::{
    io::{BufRead, Read, Write},
    net::{TcpListener, TcpStream},
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
fn owner<R: BufRead, W: Write>(input: R, mut output: W) {
    for line in input.lines() {
        match line.unwrap().as_str() {
            "begin1" => wallpaper::begin(1),
            "begin2" => wallpaper::begin(2),
            "end1" => wallpaper::end(1),
            "end2" => wallpaper::end(2),
            "crash" => std::process::exit(23), // Bypass all destructors, no forced termination.
            "quit" => return,
            value if value.starts_with("network:") => {
                let values: Vec<_> = value.split(':').collect();
                let port: u16 = values[1].parse().unwrap();
                let timeout = values[2] == "timeout";
                std::thread::spawn(move || {
                    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
                    if timeout {
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                    }
                    wallpaper::begin(3);
                    let mut byte = [0];
                    let result = stream.read(&mut byte);
                    assert!(matches!(result, Ok(0)) || timeout);
                    wallpaper::end(3);
                });
            }
            _ => panic!("unknown test command"),
        }
        writeln!(output, "accepted").unwrap();
        output.flush().unwrap();
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
    for timeout in [false, true] {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        send(&format!(
            "network:{port}:{}",
            if timeout { "timeout" } else { "eof" }
        ));
        let (peer, _) = listener.accept().unwrap();
        wait_state(&desktop, false);
        if !timeout {
            drop(peer);
        } else {
            wait_state(&desktop, true);
            drop(peer);
        }
        wait_state(&desktop, true);
        assert_eq!(snapshot(&desktop), baseline);
    }
    println!("PASS TCP peer disconnect and unresponsive-peer read timeout cleanup");
    desktop.Enable(false).unwrap();
    send("begin1");
    std::thread::sleep(Duration::from_millis(400));
    send("end1");
    std::thread::sleep(Duration::from_millis(700));
    assert!(!enabled(&desktop));
    assert_eq!(snapshot(&desktop).1, baseline.1);
    assert_eq!(
        (desktop.vtable().Enable)(desktop.as_raw(), false.into()),
        S_FALSE
    );
    println!("PASS already-disabled background stays disabled");
    desktop.Enable(true).unwrap();
    wait_state(&desktop, true);
    assert_eq!(snapshot(&desktop), baseline);
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
    system_fixture::validate(&desktop, &baseline);
    {
        use windows::Win32::UI::Shell::{
            IShellItem, IShellItemArray, SHCreateItemFromParsingName,
            SHCreateShellItemArrayFromShellItem, DESKTOP_SLIDESHOW_OPTIONS, SIGDN_FILESYSPATH,
        };
        let folder = std::env::current_dir().unwrap().join("slideshow-fixture");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::copy(&path, folder.join("first.bmp")).unwrap();
        std::fs::copy(&path, folder.join("second.bmp")).unwrap();
        let wide: Vec<u16> = folder
            .to_str()
            .unwrap()
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let item: IShellItem = SHCreateItemFromParsingName(PCWSTR(wide.as_ptr()), None).unwrap();
        let array: IShellItemArray = SHCreateShellItemArrayFromShellItem(&item).unwrap();
        desktop.SetSlideshow(&array).unwrap();
        desktop
            .SetSlideshowOptions(DESKTOP_SLIDESHOW_OPTIONS(1), 60000)
            .unwrap();
        let slideshow = desktop.GetSlideshow().unwrap();
        let count_before = slideshow.GetCount().unwrap();
        let items_before: Vec<_> = (0..count_before)
            .map(|i| {
                string(
                    slideshow
                        .GetItemAt(i)
                        .unwrap()
                        .GetDisplayName(SIGDN_FILESYSPATH)
                        .unwrap(),
                )
            })
            .collect();
        let slideshow_start = Instant::now();
        while desktop.GetStatus().unwrap().0 & 2 == 0
            && slideshow_start.elapsed() < Duration::from_secs(5)
        {
            std::thread::sleep(Duration::from_millis(100));
        }
        let original_status = desktop.GetStatus().unwrap().0;
        assert!(
            original_status & 2 != 0,
            "Slideshow fixture did not become active"
        );
        assert!(count_before > 0, "Slideshow source configuration empty");
        println!("Slideshow native status before suppression: {original_status}");
        wallpaper::begin(101);
        wait_state(&desktop, false);
        wallpaper::end(101);
        wait_state(&desktop, true);
        assert_eq!(
            desktop.GetStatus().unwrap().0,
            original_status,
            "Slideshow status changed"
        );
        let slideshow = desktop.GetSlideshow().unwrap();
        let items_after: Vec<_> = (0..slideshow.GetCount().unwrap())
            .map(|i| {
                string(
                    slideshow
                        .GetItemAt(i)
                        .unwrap()
                        .GetDisplayName(SIGDN_FILESYSPATH)
                        .unwrap(),
                )
            })
            .collect();
        assert_eq!(items_after, items_before);
        let mut options = DESKTOP_SLIDESHOW_OPTIONS(0);
        let mut tick = 0;
        desktop
            .GetSlideshowOptions(&mut options, &mut tick)
            .unwrap();
        assert_eq!(options.0, 1);
        assert_eq!(tick, 60000);
        println!(
            "PASS slideshow configuration/status preserved with identical sources/options/timing"
        );
    }
}
fn main() {
    match std::env::args().nth(1).as_deref() {
        Some(wallpaper::HELPER_ARG) => {
            if let Err(error) = wallpaper::run_helper() {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        Some("--owner") => owner(std::io::stdin().lock(), std::io::stdout().lock()),
        Some("--system-relay") => system_fixture::relay(),
        Some("--system-owner") => system_fixture::owner(),
        Some("--validate") => unsafe {
            validate();
        },
        _ => panic!("Explicit validation mode required"),
    }
}
