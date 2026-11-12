use serde_derive::Deserialize;
use serde_json::{json, Value};
use std::{
    fs,
    io::{self, ErrorKind},
    os::windows::{fs::MetadataExt, process::CommandExt},
    path::{Path, PathBuf},
    process::Command,
};
use winreg::{
    enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY, KEY_WRITE},
    RegKey,
};

const REGISTRY_PATH: &str = r"SOFTWARE\g3NetworX\OpsLinX\DeviceManagement";
const VERIFIER: &str = "verify-opslinx-package.exe";
const MANAGED_UPDATE: &str = "g3-managed-update";
const PENDING: &str = "pending.json";

#[derive(Deserialize)]
struct UpdateJob {
    id: u64,
    operation: String,
    receipt: String,
}

fn update_directory() -> io::Result<PathBuf> {
    let app = match variant() {
        Some("full") => "g3Fernwartung",
        Some("host") => "g3Host",
        _ => return Err(io::Error::new(ErrorKind::Unsupported, "Unsupported OpsLinX variant")),
    };
    let program_files = std::env::var_os("ProgramFiles").ok_or(ErrorKind::NotFound)?;
    let install = PathBuf::from(program_files).join(app);
    let current = std::env::current_exe()?;
    let installed_here = current.parent().is_some_and(|directory| {
        directory.to_string_lossy().eq_ignore_ascii_case(&install.to_string_lossy())
    });
    if !installed_here || !install.join(VERIFIER).is_file() {
        return Err(io::Error::new(ErrorKind::NotFound, "Managed update verifier is not installed"));
    }
    let directory = install.join(MANAGED_UPDATE);
    match fs::create_dir(&directory) {
        Ok(()) => (),
        Err(error) if error.kind() == ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error),
    }
    let metadata = fs::symlink_metadata(&directory)?;
    if !metadata.is_dir() || metadata.file_attributes() & 0x400 != 0 {
        return Err(io::Error::new(ErrorKind::PermissionDenied, "Unsafe managed update directory"));
    }
    Ok(directory)
}

fn resume_update(directory: &Path) -> io::Result<()> {
    Command::new(directory.join(VERIFIER))
        .arg("--managed-update")
        .creation_flags(0x08000000) // CREATE_NO_WINDOW
        .spawn()?;
    Ok(())
}

pub fn handle_update(value: &Value) -> io::Result<()> {
    let job: UpdateJob = serde_json::from_value(value.clone()).map_err(io::Error::other)?;
    if job.id == 0 || job.operation != "update" || job.receipt.len() != 43
        || !job.receipt.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(io::Error::new(ErrorKind::InvalidData, "Invalid managed update offer"));
    }
    let directory = update_directory()?;
    let pending = directory.join(PENDING);
    if pending.exists() {
        return Err(io::Error::new(ErrorKind::AlreadyExists, "A managed update is pending"));
    }
    let app = variant().ok_or(ErrorKind::Unsupported)?;
    let offer = serde_json::to_vec(&json!({"id":job.id, "receipt":job.receipt, "variant":app}))?;
    let staged = directory.join("pending.tmp");
    fs::copy(directory.with_file_name(VERIFIER), directory.join(VERIFIER))?;
    fs::write(&staged, offer)?;
    fs::rename(staged, pending)?;
    resume_update(&directory)
}

#[derive(Deserialize)]
struct Policy {
    outbound_blocked: bool,
    policy_revision: u64,
}

fn variant() -> Option<&'static str> {
    match crate::get_app_name().as_str() {
        "g3Fernwartung" => Some("full"),
        "g3Host" => Some("host"),
        _ => None,
    }
}

fn registry_path(variant: &str) -> String {
    format!("{REGISTRY_PATH}\\{variant}")
}

pub fn registration() -> io::Result<Option<Value>> {
    let Some(variant) = variant() else {
        return Ok(None);
    };
    if !crate::platform::is_root() || !crate::platform::is_installed() {
        return Ok(None);
    }
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey_with_flags(registry_path(variant), KEY_READ | KEY_WRITE | KEY_WOW64_64KEY)?;
    let installation_id: String = match key.get_value("InstallationId") {
        Ok(value) => value,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            let value = uuid::Uuid::new_v4().simple().to_string();
            key.set_value("InstallationId", &value)?;
            value
        }
        Err(error) => return Err(error),
    };
    let ready = match update_directory() {
        Ok(directory) if directory.join(PENDING).exists() => {
            if let Err(error) = resume_update(&directory) {
                hbb_common::log::warn!("Could not resume the managed update: {error}");
            }
            false
        }
        Ok(_) => true,
        Err(_) => false,
    };
    Ok(Some(json!({ "installation_id": installation_id, "variant": variant, "update_ready": ready })))
}

fn decode_policy(value: &str) -> Option<(&str, u64, bool)> {
    let (native_id, state) = value.split_once(':')?;
    let (revision, blocked) = state.split_once(':')?;
    let blocked = match blocked {
        "0" => false,
        "1" => true,
        _ => return None,
    };
    Some((native_id, revision.parse().ok()?, blocked))
}

pub fn store_policy(native_id: &str, value: &Value) -> io::Result<()> {
    let Some(variant) = variant() else {
        return Ok(());
    };
    let policy: Policy = serde_json::from_value(value.clone()).map_err(io::Error::other)?;
    let key = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(registry_path(variant), KEY_READ | KEY_WRITE | KEY_WOW64_64KEY)?;
    if let Ok(old) = key.get_value::<String, _>("OutboundPolicy") {
        if let Some((id, revision, _)) = decode_policy(&old) {
            if id == native_id && revision > policy.policy_revision {
                return Ok(());
            }
        }
    }
    let value = format!("{native_id}:{}:{}", policy.policy_revision, u8::from(policy.outbound_blocked));
    key.set_value("OutboundPolicy", &value)
}

pub fn outbound_blocked(installed_id: &str) -> bool {
    if !crate::platform::is_installed() {
        return false;
    }
    let Some(variant) = variant() else {
        return false;
    };
    let value = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(registry_path(variant), KEY_READ | KEY_WOW64_64KEY)
        .and_then(|key| key.get_value::<String, _>("OutboundPolicy"));
    let Ok(value) = value else {
        return false;
    };
    decode_policy(&value)
        .map(|(native_id, _, blocked)| blocked && (installed_id.is_empty() || installed_id == native_id))
        .unwrap_or(false)
}
