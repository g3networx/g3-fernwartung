use serde_derive::Deserialize;
use serde_json::{json, Value};
use std::io::{self, ErrorKind};
use winreg::{
    enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY, KEY_WRITE},
    RegKey,
};

const REGISTRY_PATH: &str = r"SOFTWARE\g3NetworX\OpsLinX\DeviceManagement";

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
    Ok(Some(json!({ "installation_id": installation_id, "variant": variant })))
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
