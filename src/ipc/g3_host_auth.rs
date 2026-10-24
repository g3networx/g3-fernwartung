use super::executable_paths_match;
use std::{fs,path::Path};

fn digest(path:&Path)->Option<String> {
    use hbb_common::sha2::{Digest,Sha256};
    use std::io::Read;
    let mut file=fs::File::open(path).ok()?;
    let mut hash=Sha256::new();let mut buffer=[0u8;8192];
    loop {let count=file.read(&mut buffer).ok()?;if count==0 {break}hash.update(&buffer[..count]);}
    Some(format!("{:x}",hash.finalize()))
}

fn matches_install(peer:&Path,current:&Path,root:&Path,core_hash:&str,ui_hash:&str)->bool {
    let (Ok(core),Ok(ui))=(fs::canonicalize(root.join("g3Host.exe")),fs::canonicalize(root.join("g3Host-ui.exe"))) else {return false};
    if !((executable_paths_match(peer,&core) && executable_paths_match(current,&ui))
        || (executable_paths_match(peer,&ui) && executable_paths_match(current,&core))) {return false}
    core_hash.len()==64 && ui_hash.len()==64
        && digest(&core).as_deref()==Some(core_hash) && digest(&ui).as_deref()==Some(ui_hash)
}

pub(super) fn installed_pair(peer:&Path,current:&Path)->bool {
    use winreg::{enums::{HKEY_LOCAL_MACHINE,KEY_READ,KEY_WOW64_64KEY},RegKey};
    if crate::get_app_name()!="g3Host" {return false}
    let Ok(key)=RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(
        "Software\\g3Host\\InstallState\\g3Host",KEY_READ|KEY_WOW64_64KEY) else {return false};
    if key.get_value::<u32,_>("WindowsInstaller").ok()!=Some(1) {return false}
    let (Ok(root),Ok(core),Ok(ui))=(key.get_value::<String,_>("InstallLocation"),
        key.get_value::<String,_>("HostCoreSha256"),key.get_value::<String,_>("HostUiSha256")) else {return false};
    matches_install(peer,current,Path::new(&root),&core,&ui)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_exact_installed_host_pair_with_matching_hashes_is_trusted() {
        let root=std::env::temp_dir().join(format!("g3-host-pair-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir(&root).unwrap();
        let core=root.join("g3Host.exe");let ui=root.join("g3Host-ui.exe");
        fs::write(&core,b"fixture native launcher").unwrap();fs::write(&ui,b"fixture Host UI").unwrap();
        let core=fs::canonicalize(core).unwrap();let ui=fs::canonicalize(ui).unwrap();
        let ch=digest(&core).unwrap();let uh=digest(&ui).unwrap();
        assert!(matches_install(&core,&ui,&root,&ch,&uh));assert!(matches_install(&ui,&core,&root,&ch,&uh));
        assert!(!matches_install(&root.join("untrusted.exe"),&core,&root,&ch,&uh));
        assert!(!matches_install(&ui,&core,&root,"",&uh));
        fs::write(&ui,b"modified Host UI").unwrap();assert!(!matches_install(&ui,&core,&root,&ch,&uh));
        fs::remove_dir_all(root).unwrap();
    }
}
