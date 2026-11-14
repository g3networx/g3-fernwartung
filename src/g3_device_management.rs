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
// DeviceManagement inherits the credential store's private ACL on some
// installations. The public state contains only the decision and revision.
const OUTBOUND_POLICY_PATH: &str = r"SOFTWARE\g3OpsLinXOutboundPolicy";
const VERIFIER: &str = "verify-opslinx-package.exe";
const MANAGED_UPDATE: &str = "g3-managed-update";
const PENDING: &str = "pending.json";

#[derive(Deserialize)]
struct ManagedJob {
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

pub fn handle_job(value: &Value) -> io::Result<()> {
    let job: ManagedJob = serde_json::from_value(value.clone()).map_err(io::Error::other)?;
    if job.id == 0 || !matches!(job.operation.as_str(), "update" | "uninstall") || job.receipt.len() != 43
        || !job.receipt.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(io::Error::new(ErrorKind::InvalidData, "Invalid device management offer"));
    }
    let directory = update_directory()?;
    let pending = directory.join(PENDING);
    if pending.exists() {
        return Err(io::Error::new(ErrorKind::AlreadyExists, "A managed update is pending"));
    }
    let app = variant().ok_or(ErrorKind::Unsupported)?;
    let offer = serde_json::to_vec(&json!({
        "id": job.id, "receipt": job.receipt, "variant": app, "operation": job.operation,
    }))?;
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
    Ok(Some(json!({
        "installation_id": installation_id, "variant": variant,
        "update_ready": ready, "uninstall_supported": true,
    })))
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
    let root = RegKey::predef(HKEY_LOCAL_MACHINE);
    let (key, _) = root.create_subkey_with_flags(
        format!(r"{OUTBOUND_POLICY_PATH}\{variant}"), KEY_READ | KEY_WRITE | KEY_WOW64_64KEY,
    )?;
    let previous = key.get_value::<String, _>("OutboundPolicy").or_else(|_| {
        root.open_subkey_with_flags(registry_path(variant), KEY_READ | KEY_WOW64_64KEY)?
            .get_value("OutboundPolicy")
    });
    if let Ok(old) = previous {
        if let Some((id, revision, _)) = decode_policy(&old) {
            if id == native_id && revision > policy.policy_revision {
                return key.set_value("OutboundPolicy", &old);
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
    // Host and FullClient can share one installed identity. In that case
    // the Host service may be the one that receives the portal policy.
    let sibling = if variant == "full" { "host" } else { "full" };
    [variant, sibling].into_iter().filter_map(|source| {
        let value = RegKey::predef(HKEY_LOCAL_MACHINE)
            .open_subkey_with_flags(format!(r"{OUTBOUND_POLICY_PATH}\{source}"), KEY_READ | KEY_WOW64_64KEY)
            .and_then(|key| key.get_value::<String, _>("OutboundPolicy")).ok()?;
        let (native_id, revision, blocked) = decode_policy(&value)?;
        (installed_id == native_id || (source == variant && installed_id.is_empty()))
            .then_some((revision, blocked))
    }).max().is_some_and(|(_, blocked)| blocked)
}
