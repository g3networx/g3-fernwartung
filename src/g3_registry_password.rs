//! Update-independent supplemental standard credential; never a replacement for user credentials.
use std::{ffi::c_void, ptr};
use winreg::{enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY, KEY_WRITE, REG_BINARY}, RegKey};
use hbb_common::config::Config;

#[repr(C)]
struct Blob { len: u32, data: *mut u8 }
#[link(name="crypt32")]
extern "system" {
    fn CryptProtectData(input:*mut Blob,description:*const u16,entropy:*mut Blob,
        reserved:*mut c_void,prompt:*mut c_void,flags:u32,output:*mut Blob)->i32;
    fn CryptUnprotectData(input:*mut Blob,description:*mut *mut u16,entropy:*mut Blob,
        reserved:*mut c_void,prompt:*mut c_void,flags:u32,output:*mut Blob)->i32;
}
#[link(name="kernel32")]
extern "system" { fn LocalFree(value:*mut c_void)->*mut c_void; }

fn managed_instance()->bool {crate::platform::is_installed() && crate::platform::is_root() && matches!(crate::get_app_name().as_str(),"g3Host"|"g3Fernwartung")}
fn bound_identity(app:&str,id:&str)->bool {
    matches!(app,"g3Host"|"g3Fernwartung") && (6..=12).contains(&id.len()) && id.bytes().all(|b|b.is_ascii_digit())
}
fn entropy(app:&str,id:&str)->Vec<u8> {format!("OpsLinX-Standard-v1\0{}\0{}",app,id).into_bytes()}
fn unprotect_purpose(encrypted:&mut [u8],app:&str,id:&str,purpose:&str)->Option<Vec<u8>> {
    if !bound_identity(app,id) || encrypted.is_empty() || encrypted.len()>65536{return None}
    let mut salt=purpose_entropy(app,id,purpose);
    let mut input=Blob{len:encrypted.len() as u32,data:encrypted.as_mut_ptr()};
    let mut extra=Blob{len:salt.len() as u32,data:salt.as_mut_ptr()};
    let mut output=Blob{len:0,data:ptr::null_mut()};
    let ok=unsafe{CryptUnprotectData(&mut input,ptr::null_mut(),&mut extra,ptr::null_mut(),ptr::null_mut(),1,&mut output)};
    if ok==0{return None}
    let result=if !output.data.is_null() && output.len<=65536 {
        Some(unsafe{std::slice::from_raw_parts(output.data,output.len as usize)}.to_vec())
    }else{None};
    if !output.data.is_null(){unsafe{
        std::ptr::write_bytes(output.data,0,output.len as usize);LocalFree(output.data.cast());
    }}
    result
}
fn purpose_entropy(app:&str,id:&str,purpose:&str)->Vec<u8> {
    if purpose=="standard" {entropy(app,id)}else{format!("OpsLinX-DevicePasswords-v1\0{}\0{}",app,id).into_bytes()}
}
fn unprotect(encrypted:&mut [u8],app:&str,id:&str)->Option<Vec<u8>> {unprotect_purpose(encrypted,app,id,"standard")}
fn protect_bytes(plain:&mut [u8],app:&str,id:&str,purpose:&str)->Option<Vec<u8>> {
    if !bound_identity(app,id) || plain.is_empty() || plain.len()>65536{return None}
    let mut salt=purpose_entropy(app,id,purpose);
    let mut input=Blob{len:plain.len() as u32,data:plain.as_mut_ptr()};
    let mut extra=Blob{len:salt.len() as u32,data:salt.as_mut_ptr()};
    let mut output=Blob{len:0,data:ptr::null_mut()};
    let ok=unsafe{CryptProtectData(&mut input,ptr::null(),&mut extra,ptr::null_mut(),ptr::null_mut(),5,&mut output)};
    if ok==0{return None}
    let result=if !output.data.is_null() && output.len<=65536 {Some(unsafe{std::slice::from_raw_parts(output.data,output.len as usize)}.to_vec())}else{None};
    if !output.data.is_null(){unsafe{LocalFree(output.data.cast());}}result
}
pub(crate) fn with_standard_password<F:FnOnce(&str)->bool>(validate:F)->bool {
    if !crate::platform::is_installed() || !crate::platform::is_root(){return false}
    let app=crate::get_app_name();let id=Config::get_id();
    if !bound_identity(&app,&id){return false}
    let Ok(key)=RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(
        format!(r"SOFTWARE\g3NetworX\OpsLinX\CredentialAnchor\{}\{}",app,id),KEY_READ|KEY_WOW64_64KEY) else{return false};
    if !restricted_key(&key){return false}
    if key.get_value::<u32,_>("Schema").ok()!=Some(1)
        || key.get_value::<String,_>("NativeId").ok().as_deref()!=Some(id.as_str())
        || key.get_value::<String,_>("Product").ok().as_deref()!=Some(app.as_str()){return false}
    let Ok(mut value)=key.get_raw_value("ProtectedStandard") else{return false};
    if value.vtype!=REG_BINARY{return false}
    let Some(mut secret)=unprotect(&mut value.bytes,&app,&id) else{return false};
    let accepted=match std::str::from_utf8(&secret) {
        Ok(password) if (8..=128).contains(&password.chars().count())=>validate(password),
        _=>false,
    };
    secret.fill(0);accepted
}
pub(crate) fn enable_password_alternatives() {
    if with_standard_password(|_|true) && Config::get_option("verification-method")!="use-both-passwords" {
        Config::set_option("verification-method".into(),"use-both-passwords".into());
    }
}


// One encrypted atomic value owns all persistent device-password state. OTP is
// deliberately absent. The profile is only a compatibility mirror after migration.
#[derive(Clone,PartialEq,serde::Serialize,serde::Deserialize,Default)]
struct Persistent {
    revision:u64,
    permanent:Option<(String,String)>,
    local:Option<(String,String)>,
    managed:Option<String>,
}
static CREDENTIAL_LOCK:std::sync::Mutex<()>=std::sync::Mutex::new(());
const REVISION:&str="g3-password-registry-revision";
#[repr(C)]
struct SecurityAttributes {len:u32,descriptor:*mut c_void,inherit:i32}
#[link(name="advapi32")]
extern "system" {
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(value:*const u16,revision:u32,
        descriptor:*mut *mut c_void,size:*mut u32)->i32;
    fn RegCreateKeyExW(parent:*mut c_void,path:*const u16,reserved:u32,class:*mut u16,options:u32,
        access:u32,attributes:*mut SecurityAttributes,key:*mut *mut c_void,disposition:*mut u32)->i32;
    fn RegCloseKey(key:*mut c_void)->i32;
    fn GetSecurityInfo(handle:*mut c_void,kind:u32,info:u32,owner:*mut *mut c_void,
        group:*mut *mut c_void,dacl:*mut *mut c_void,sacl:*mut *mut c_void,descriptor:*mut *mut c_void)->u32;
    fn GetSecurityDescriptorControl(descriptor:*mut c_void,control:*mut u16,revision:*mut u32)->i32;
    fn GetAce(acl:*mut c_void,index:u32,ace:*mut *mut c_void)->i32;
    fn GetSecurityDescriptorOwner(descriptor:*mut c_void,owner:*mut *mut c_void,defaulted:*mut i32)->i32;
    fn GetSecurityDescriptorDacl(descriptor:*mut c_void,present:*mut i32,dacl:*mut *mut c_void,defaulted:*mut i32)->i32;
    fn ConvertSidToStringSidW(sid:*mut c_void,value:*mut *mut u16)->i32;
}

fn allowed_sid(sid:*mut c_void)->bool {
    if sid.is_null(){return false}
    let mut value=ptr::null_mut();
    if unsafe{ConvertSidToStringSidW(sid,&mut value)}==0{return false}
    let mut len=0;while len<128 && unsafe{*value.add(len)}!=0 {len+=1;}
    let text=unsafe{std::slice::from_raw_parts(value,len)};
    let result=String::from_utf16(text).map(|s|s=="S-1-5-18" || s=="S-1-5-32-544").unwrap_or(false);
    unsafe{LocalFree(value.cast());}result
}
#[repr(C)]
struct AclHeader {revision:u8,reserved:u8,size:u16,count:u16,reserved2:u16}
fn restricted_key(key:&RegKey)->bool {
    let mut owner=ptr::null_mut();let mut dacl=ptr::null_mut();let mut descriptor=ptr::null_mut();
    if unsafe{GetSecurityInfo(key.raw_handle().cast(),4,5,&mut owner,ptr::null_mut(),&mut dacl,ptr::null_mut(),&mut descriptor)}!=0{return false}
    let allowed=restricted_descriptor(owner,dacl,descriptor);
    if !descriptor.is_null(){unsafe{LocalFree(descriptor);}}allowed
}
fn restricted_descriptor(owner:*mut c_void,dacl:*mut c_void,descriptor:*mut c_void)->bool {
    let mut control=0;let mut revision=0;
    let mut allowed=allowed_sid(owner) && !dacl.is_null()
        && unsafe{GetSecurityDescriptorControl(descriptor,&mut control,&mut revision)}!=0 && control&0x1000!=0;
    if allowed {
        let count=unsafe{(*(dacl as *const AclHeader)).count};
        for index in 0..count {
            let mut ace=ptr::null_mut();
            if unsafe{GetAce(dacl,index as u32,&mut ace)}==0 {allowed=false;break}
            let kind=unsafe{*(ace as *const u8)};
            if kind==0 {
                if !allowed_sid(unsafe{(ace as *mut u8).add(8)}.cast()){allowed=false;break}
            } else if kind!=1 {allowed=false;break}
        }
    }
    allowed
}
fn owned_key(app:&str,id:&str)->Result<RegKey,()> {
    if !bound_identity(app,id){return Err(())}
    let root=RegKey::predef(HKEY_LOCAL_MACHINE);
    let path=format!(r"SOFTWARE\g3NetworX\OpsLinX\CredentialAnchor\{}\{}",app,id);
    let read_write=KEY_READ|KEY_WRITE|KEY_WOW64_64KEY;
    let key=match root.open_subkey_with_flags(&path,read_write) {
        Ok(key)=>key,
        Err(error) if error.kind()==std::io::ErrorKind::NotFound=>{
            // Create the final credential leaf atomically with no inherited users.
            let wide:Vec<u16>=path.encode_utf16().chain(Some(0)).collect();
            let sddl:Vec<u16>="O:BAG:BAD:P(A;CI;KA;;;SY)(A;CI;KA;;;BA)".encode_utf16().chain(Some(0)).collect();
            let mut descriptor=ptr::null_mut();let mut handle=ptr::null_mut();let mut disposition=0;
            if unsafe{ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(),1,&mut descriptor,ptr::null_mut())}==0{return Err(())}
            let mut attributes=SecurityAttributes{len:std::mem::size_of::<SecurityAttributes>() as u32,descriptor,inherit:0};
            let result=unsafe{RegCreateKeyExW(root.raw_handle().cast(),wide.as_ptr(),0,ptr::null_mut(),0,read_write,&mut attributes,&mut handle,&mut disposition)};
            unsafe{LocalFree(descriptor);}
            if result!=0{return Err(())}
            unsafe{RegCloseKey(handle);}
            root.open_subkey_with_flags(&path,read_write).map_err(|_|())?
        }
        Err(_)=>return Err(()),
    };
    if !restricted_key(&key){return Err(())}
    if let Ok(schema)=key.get_value::<u32,_>("Schema") {if schema!=1{return Err(())}}
    // An existing binding must never be silently reassigned to another identity.
    if let Ok(existing)=key.get_value::<String,_>("NativeId") {if existing!=id{return Err(())}}
    if let Ok(existing)=key.get_value::<String,_>("Product") {if existing!=app{return Err(())}}
    if key.get_value::<u32,_>("Schema").ok()!=Some(1){key.set_value("Schema",&1u32).map_err(|_|())?;}
    if key.get_value::<String,_>("NativeId").is_err(){key.set_value("NativeId",&id).map_err(|_|())?;}
    if key.get_value::<String,_>("Product").is_err(){key.set_value("Product",&app).map_err(|_|())?;}
    Ok(key)
}
fn load(key:&RegKey,app:&str,id:&str)->Result<Option<Persistent>,()> {
    let mut value=match key.get_raw_value("ProtectedDevicePasswords") {
        Ok(v)=>v,Err(e) if e.kind()==std::io::ErrorKind::NotFound=>return Ok(None),Err(_)=>return Err(()),
    };
    if value.vtype!=REG_BINARY{return Err(())}
    let mut bytes=unprotect_purpose(&mut value.bytes,app,id,"device").ok_or(())?;
    let parsed=serde_json::from_slice::<Persistent>(&bytes).map_err(|_|());bytes.fill(0);
    parsed.map(Some)
}
fn save(key:&RegKey,app:&str,id:&str,value:&Persistent)->Result<(),()> {
    let mut plain=serde_json::to_vec(value).map_err(|_|())?;
    let encrypted=protect_bytes(&mut plain,app,id,"device");plain.fill(0);
    let bytes=encrypted.ok_or(())?;
    key.set_raw_value("ProtectedDevicePasswords",&winreg::RegValue{bytes,vtype:REG_BINARY}).map_err(|_|())?;
    if load(key,app,id)?.as_ref()!=Some(value){return Err(())}Ok(())
}
fn profile_snapshot()->Persistent {
    let (storage,salt)=Config::get_local_permanent_password_storage_and_salt();
    let local=Config::get_option("g3-local-passwords");let managed=Config::get_option("g3-service-password");
    Persistent{revision:1,permanent:if storage.is_empty(){None}else{Some((storage,salt))},
        local:if local.is_empty(){None}else{Some((local,Config::get_option("g3-local-password-labels")))},
        managed:if managed.is_empty(){None}else{Some(managed)}}
}
fn mirror(value:&Persistent)->Result<(),()> {
    if let Some((storage,salt))=&value.permanent {
        if Config::get_local_permanent_password_storage_and_salt()!=(storage.clone(),salt.clone()) {
            Config::set_permanent_password_storage_for_sync(storage,salt).map_err(|_|())?;
        }
    }
    let mut options=Config::get_options();merge_credentials(&mut options,value);
    if Config::get_options()!=options{Config::set_options(options)}Ok(())
}
fn merge_credentials(options:&mut std::collections::HashMap<String,String>,value:&Persistent) {
    if let Some((passwords,labels))=&value.local {
        options.insert("g3-local-passwords".into(),passwords.clone());options.insert("g3-local-password-labels".into(),labels.clone());
    }
    if let Some(managed)=&value.managed{options.insert("g3-service-password".into(),managed.clone());}
    options.insert("verification-method".into(),"use-both-passwords".into());
    options.insert(REVISION.into(),value.revision.to_string());
}
fn context()->Result<(RegKey,String,String,Persistent),()> {
    if !crate::platform::is_installed() || !crate::platform::is_root(){return Err(())}
    let app=crate::get_app_name();let id=Config::get_id();let key=owned_key(&app,&id)?;
    let value=match load(&key,&app,&id)? {Some(v)=>v,None=>{let v=profile_snapshot();save(&key,&app,&id,&v)?;v}};
    Ok((key,app,id,value))
}
pub(crate) fn restore_profile()->Result<(),()> {
    if !managed_instance(){return Ok(())}
    let _guard=CREDENTIAL_LOCK.lock().map_err(|_|())?;let (_,_,_,value)=context()?;mirror(&value)
}
pub(crate) fn authoritative_options()->std::collections::HashMap<String,String> {
    let _=restore_profile();Config::get_options()
}
pub(crate) fn save_explicit_permanent()->Result<(),()> {
    if !managed_instance(){return Ok(())}
    let _guard=CREDENTIAL_LOCK.lock().map_err(|_|())?;let (key,app,id,mut value)=context()?;
    value.permanent=Some(Config::get_local_permanent_password_storage_and_salt());value.revision+=1;
    save(&key,&app,&id,&value)?;mirror(&value)
}
fn options_update(value:&Persistent,incoming:&std::collections::HashMap<String,String>)->Result<Persistent,()> {
    let mut next=value.clone();
    if let Some(passwords)=incoming.get("g3-local-passwords") {
        next.local=Some((passwords.clone(),incoming.get("g3-local-password-labels").cloned().unwrap_or_default()));
    }
    if let Some(managed)=incoming.get("g3-service-password"){next.managed=Some(managed.clone());}
    if next!=*value {
        if incoming.get(REVISION).and_then(|s|s.parse::<u64>().ok())!=Some(value.revision){return Err(())}
        next.revision+=1;
    }
    Ok(next)
}
pub(crate) fn apply_explicit_options(mut incoming:std::collections::HashMap<String,String>)->Result<(),()> {
    if !managed_instance(){Config::set_options(incoming);return Ok(())}
    let _guard=CREDENTIAL_LOCK.lock().map_err(|_|())?;let (key,app,id,value)=context()?;
    if incoming.get("verification-method").is_some_and(|mode|!mode.is_empty() && mode!="use-both-passwords"){return Err(())}
    let next=options_update(&value,&incoming)?;
    if next!=value{save(&key,&app,&id,&next)?;}
    merge_credentials(&mut incoming,&next);Config::set_options(incoming);Ok(())
}
fn seed_managed(value:&Persistent,candidate:&str)->Persistent {
    let mut next=value.clone();
    // Web parameters only fill an uninitialised slot; existing device values win.
    if next.managed.is_none() && !candidate.is_empty(){next.managed=Some(candidate.into());next.revision+=1;}
    next
}
pub(crate) fn seed_web_parameters(candidate:&str)->Result<(),()> {
    if !managed_instance(){
        if Config::get_option("g3-service-password").is_empty(){Config::set_option("g3-service-password".into(),candidate.into());}
        return Ok(());
    }
    let _guard=CREDENTIAL_LOCK.lock().map_err(|_|())?;let (key,app,id,value)=context()?;
    let next=seed_managed(&value,candidate);
    if next!=value{save(&key,&app,&id,&next)?;}mirror(&next)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn protect(app:&str,id:&str)->Vec<u8> {
        let mut plain=b"fixture-standard-password".to_vec();let mut salt=entropy(app,id);
        let mut input=Blob{len:plain.len() as u32,data:plain.as_mut_ptr()};
        let mut extra=Blob{len:salt.len() as u32,data:salt.as_mut_ptr()};
        let mut output=Blob{len:0,data:ptr::null_mut()};
        assert_ne!(unsafe{CryptProtectData(&mut input,ptr::null(),&mut extra,ptr::null_mut(),ptr::null_mut(),5,&mut output)},0);
        let encrypted=unsafe{std::slice::from_raw_parts(output.data,output.len as usize)}.to_vec();
        plain.fill(0);unsafe{LocalFree(output.data.cast());}encrypted
    }
    #[test]
    fn real_machine_dpapi_roundtrip_and_identity_binding() {
        let mut encrypted=protect("g3Host","123456789");
        assert_eq!(unprotect(&mut encrypted,"g3Host","123456789").unwrap(),b"fixture-standard-password");
        assert!(unprotect(&mut encrypted,"g3Host","123456788").is_none());
        assert!(unprotect(&mut encrypted,"g3Fernwartung","123456789").is_none());
    }
    #[test]
    fn corrupt_or_unbound_storage_never_becomes_a_password() {
        assert!(unprotect(&mut [1,2,3],"g3Host","123456789").is_none());
        assert!(unprotect(&mut [],"g3Host","123456789").is_none());
        assert!(!bound_identity("unknown","123456789"));assert!(!bound_identity("g3Host","unknown"));
    }
    #[test]
    fn web_parameters_cannot_replace_existing_device_passwords() {
        let original=Persistent{revision:7,permanent:Some(("owned-hash".into(),"owned-salt".into())),local:Some(("owned-additional".into(),"labels".into())),managed:Some("owned-managed".into())};
        assert!(seed_managed(&original,"different-web")==original);
        let empty=Persistent::default();let seeded=seed_managed(&empty,"initial-web");
        assert!(seeded.managed.as_deref()==Some("initial-web"));
        assert!(seed_managed(&seeded,"later-web")==seeded);
    }
    #[test]
    fn stale_ui_options_cannot_erase_newer_passwords() {
        let original=Persistent{revision:9,local:Some(("new".into(),"labels".into())),..Default::default()};
        let mut incoming=std::collections::HashMap::new();incoming.insert("g3-local-passwords".into(),"old".into());incoming.insert(REVISION.into(),"8".into());
        assert!(options_update(&original,&incoming).is_err());
        incoming.clear();assert!(options_update(&original,&incoming).unwrap()==original);
        incoming.insert("g3-local-passwords".into(),"explicit-new".into());incoming.insert(REVISION.into(),"9".into());
        assert!(options_update(&original,&incoming).unwrap().revision==10);
    }
    #[test]
    fn durable_state_roundtrip_contains_no_otp_and_is_purpose_bound() {
        let state=Persistent{revision:1,permanent:Some(("fixture-hash".into(),"fixture-salt".into())),local:Some(("fixture-local".into(),"fixture-labels".into())),managed:Some("fixture-managed".into())};
        let mut plain=serde_json::to_vec(&state).unwrap();assert!(!String::from_utf8_lossy(&plain).contains("temporary"));
        let mut encrypted=protect_bytes(&mut plain,"g3Host","123456789","device").unwrap();plain.fill(0);
        assert!(unprotect(&mut encrypted,"g3Host","123456789").is_none());
        let mut decoded=unprotect_purpose(&mut encrypted,"g3Host","123456789","device").unwrap();
        assert!(serde_json::from_slice::<Persistent>(&decoded).unwrap()==state);decoded.fill(0);
    }

    #[test]
    fn real_windows_acl_parser_rejects_inherited_or_user_access() {
        for (text,expected) in [
            ("O:BAG:BAD:P(A;CI;KA;;;SY)(A;CI;KA;;;BA)",true),
            ("O:BAG:BAD:(A;CI;KA;;;SY)(A;CI;KA;;;BA)",false),
            ("O:BAG:BAD:P(A;CI;KA;;;SY)(A;CI;KR;;;BU)",false),
            ("O:BAG:BAD:P(A;CI;KA;;;SY)(A;CI;KR;;;WD)",false),
        ] {
            let wide:Vec<u16>=text.encode_utf16().chain(Some(0)).collect();
            let mut descriptor=ptr::null_mut();
            assert_ne!(unsafe{ConvertStringSecurityDescriptorToSecurityDescriptorW(wide.as_ptr(),1,&mut descriptor,ptr::null_mut())},0);
            let mut owner=ptr::null_mut();let mut dacl=ptr::null_mut();let mut defaulted=0;let mut present=0;
            assert_ne!(unsafe{GetSecurityDescriptorOwner(descriptor,&mut owner,&mut defaulted)},0);
            assert_ne!(unsafe{GetSecurityDescriptorDacl(descriptor,&mut present,&mut dacl,&mut defaulted)},0);
            assert_eq!(restricted_descriptor(owner,dacl,descriptor),expected);
            unsafe{LocalFree(descriptor);}
        }
    }

    #[test]
    fn compatibility_mirror_retains_credentials_and_both_password_modes() {
        let value=Persistent{revision:3,local:Some(("fixture-additional".into(),"fixture-labels".into())),managed:Some("fixture-managed".into()),..Default::default()};
        let mut options=std::collections::HashMap::new();options.insert("verification-method".into(),"use-permanent-password".into());options.insert("unrelated".into(),"keep".into());
        merge_credentials(&mut options,&value);
        assert!(options.get("verification-method").map(String::as_str)==Some("use-both-passwords"));
        assert!(options.get("g3-local-passwords").map(String::as_str)==Some("fixture-additional"));
        assert!(options.get("unrelated").map(String::as_str)==Some("keep"));
    }

}
