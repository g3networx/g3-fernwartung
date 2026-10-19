pub(crate) fn enrollment_source() -> String {
    use winreg::{enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY}, RegKey};
    let app = crate::get_app_name();
    if !matches!(app.as_str(), "g3Fernwartung" | "g3Host") { return String::new(); }
    let path = format!("Software\\{}\\InstallState\\{}", app, app);
    let source = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(path, KEY_READ | KEY_WOW64_64KEY)
        .and_then(|key| key.get_value::<String, _>("EnrollmentSource"));
    match source {
        Ok(value) if value.len() <= 4096 => value,
        _ => String::new(),
    }
}
