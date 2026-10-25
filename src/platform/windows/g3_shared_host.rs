//! A co-installed FullClient uses the installed Host's existing device endpoint.
use std::{fs, io::Read, path::{Path, PathBuf}};
use hbb_common::sha2::{Digest, Sha256};
use winreg::{enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY}, RegKey};

struct Installed { root: PathBuf, executable: PathBuf, hash: String }

fn installed(app: &str) -> Option<Installed> {
    let key=RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(
        format!("Software\\{app}\\InstallState\\{app}"), KEY_READ|KEY_WOW64_64KEY).ok()?;
    if key.get_value::<u32,_>("WindowsInstaller").ok()!=Some(1)
        || key.get_value::<u32,_>("SharedDeviceIdentityProtocol").ok()!=Some(1) { return None; }
    let root=fs::canonicalize(key.get_value::<String,_>("InstallLocation").ok()?).ok()?;
    let executable=fs::canonicalize(root.join(format!("{app}.exe"))).ok()?;
    let hash=key.get_value::<String,_>(if app=="g3Host" {"HostCoreSha256"} else {"FullUiSha256"}).ok()?;
    if hash.len()!=64 || !hash.bytes().all(|b|b.is_ascii_hexdigit()) { return None; }
    Some(Installed {root,executable,hash})
}

pub(crate) fn uses_host() -> bool {
    crate::get_app_name()=="g3Fernwartung" && crate::platform::is_installed()
        && installed("g3Host").is_some() && installed("g3Fernwartung").is_some()
}

pub(crate) fn ipc_path(postfix: &str) -> Option<String> {
    if std::env::args().any(|arg|arg=="--service") {return None;}
    if !postfix.is_empty() && postfix!=crate::POSTFIX_SERVICE {return None;}
    uses_host().then(||format!(r"\\.\pipe\g3Host\query{postfix}"))
}

pub(crate) async fn standby() {
    while uses_host() {
        hbb_common::tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
}

pub(crate) fn config_synced() {
    if uses_host() {hbb_common::config::g3_reset_key_pair_cache();}
}

pub(crate) fn sibling_gate() -> Option<PathBuf> {
    if !crate::platform::is_installed() { return None; }
    let app=crate::get_app_name();
    let sibling=match app.as_str() {"g3Host"=>"g3Fernwartung", "g3Fernwartung"=>"g3Host", _=>return None};
    installed(&app)?;
    Some(installed(sibling)?.root.join(crate::g3_update_gate::FILE_NAME))
}

fn digest(path: &Path) -> Option<String> {
    let mut file=fs::File::open(path).ok()?;let mut hash=Sha256::new();let mut buffer=[0u8;8192];
    loop {let count=file.read(&mut buffer).ok()?;if count==0 {break;}hash.update(&buffer[..count]);}
    Some(format!("{:x}",hash.finalize()))
}

fn matches_pair(peer: &Path,current: &Path,host: &Installed,full: &Installed) -> bool {
    let (Ok(peer),Ok(current))=(fs::canonicalize(peer),fs::canonicalize(current)) else {return false;};
    let same=|a:&Path,b:&Path|a.to_string_lossy().eq_ignore_ascii_case(&b.to_string_lossy());
    ((same(&peer,&host.executable)&&same(&current,&full.executable))
        || (same(&peer,&full.executable)&&same(&current,&host.executable)))
        && digest(&host.executable).as_deref()==Some(host.hash.as_str())
        && digest(&full.executable).as_deref()==Some(full.hash.as_str())
}

pub(crate) fn trusted_pair(peer: &Path,current: &Path) -> bool {
    let (Some(host),Some(full))=(installed("g3Host"),installed("g3Fernwartung")) else {return false;};
    matches_pair(peer,current,&host,&full)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_the_hash_pinned_installed_host_and_full_pair_share_authority() {
        let root=std::env::temp_dir().join(format!("g3-shared-id-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir(&root).unwrap();
        let h=root.join("g3Host.exe");let f=root.join("g3Fernwartung.exe");
        fs::write(&h,b"fixture Host").unwrap();fs::write(&f,b"fixture Full").unwrap();
        let host=Installed{root:root.clone(),executable:fs::canonicalize(&h).unwrap(),hash:digest(&h).unwrap()};
        let full=Installed{root:root.clone(),executable:fs::canonicalize(&f).unwrap(),hash:digest(&f).unwrap()};
        assert!(matches_pair(&h,&f,&host,&full));assert!(matches_pair(&f,&h,&host,&full));
        assert!(!matches_pair(&h,&h,&host,&full));
        let other=root.join("untrusted.exe");fs::write(&other,b"fixture Full").unwrap();
        assert!(!matches_pair(&h,&other,&host,&full));
        fs::write(&f,b"modified Full").unwrap();assert!(!matches_pair(&h,&f,&host,&full));
        fs::remove_dir_all(root).unwrap();
    }
}
