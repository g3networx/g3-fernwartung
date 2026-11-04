//! One-use encrypted transfer of the unchanged service OTP to an installed probe.
use std::{ffi::{CStr, CString}, fs::File, io::Read, os::raw::c_char,
    os::windows::{fs::OpenOptionsExt, io::AsRawHandle}, sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH}};
use hbb_common::sodiumoxide::crypto::{box_, sealedbox};
use serde::{Deserialize, Serialize};

const PURPOSE: &str = "OpsLinX-current-OTP-v1";
const KEY_TTL: Duration = Duration::from_secs(60);

struct ProbeKey {
    public: box_::PublicKey,
    secret: box_::SecretKey,
    id: String,
    nonce: String,
    created: Instant,
}
lazy_static::lazy_static! { static ref PROBE_KEY: Mutex<Option<ProbeKey>> = Mutex::new(None); }

#[derive(Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
struct Request { expected_native_id: String, nonce: String, recipient_public_key: String }

#[derive(Serialize, Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
struct Payload {
    purpose: String,
    native_id: String,
    nonce: String,
    issued_at: u64,
    expires_at: u64,
    password: String,
}
impl Drop for Payload {
    fn drop(&mut self) { unsafe { self.password.as_mut_vec().fill(0); } }
}

fn now() -> Result<u64, ()> {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|v|v.as_secs()).map_err(|_|())
}
fn valid_id(id: &str) -> bool { (6..=12).contains(&id.len()) && id.bytes().all(|b|b.is_ascii_digit()) }
fn valid_nonce(nonce: &str) -> bool { nonce.len()==32 && nonce.bytes().all(|b|b.is_ascii_hexdigit()) }
fn installed_admin() -> bool {
    matches!(crate::get_app_name().as_str(), "g3Host"|"g3Fernwartung")
        && crate::platform::is_installed() && crate::platform::is_cur_exe_the_installed()
        && (crate::platform::is_root() || crate::platform::is_elevated(None).unwrap_or(false))
}

#[repr(C)]
struct WtsSession { id: u32, station: *mut u16, state: u32 }
#[repr(C)]
struct Overlapped { internal: usize, internal_high: usize, offset: u32, offset_high: u32, event: *mut std::ffi::c_void }
#[link(name="wtsapi32")]
extern "system" {
    fn WTSEnumerateSessionsW(server: *mut std::ffi::c_void, reserved:u32, version:u32, sessions:*mut *mut WtsSession, count:*mut u32)->i32;
    fn WTSQuerySessionInformationW(server:*mut std::ffi::c_void, id:u32, class:u32, buffer:*mut *mut u16, bytes:*mut u32)->i32;
    fn WTSFreeMemory(memory:*mut std::ffi::c_void);
}
#[link(name="kernel32")]
extern "system" {
    fn LockFileEx(handle:*mut std::ffi::c_void, flags:u32, reserved:u32, low:u32, high:u32, overlapped:*mut Overlapped)->i32;
}
struct WtsMemory(*mut std::ffi::c_void);
impl Drop for WtsMemory { fn drop(&mut self) { if !self.0.is_null() { unsafe { WTSFreeMemory(self.0); } } } }

fn unoccupied() -> Result<(), ()> {
    let mut sessions=std::ptr::null_mut();let mut count=0;
    if unsafe { WTSEnumerateSessionsW(std::ptr::null_mut(),0,1,&mut sessions,&mut count) }==0 { return Err(()); }
    let _memory=WtsMemory(sessions.cast());
    if sessions.is_null() || count>4096 { return Err(()); }
    for entry in unsafe { std::slice::from_raw_parts(sessions,count as usize) } {
        if entry.id==0 { continue; }
        let mut name=std::ptr::null_mut();let mut bytes=0;
        if unsafe { WTSQuerySessionInformationW(std::ptr::null_mut(),entry.id,5,&mut name,&mut bytes) }==0 { return Err(()); }
        let _name=WtsMemory(name.cast());
        if name.is_null() || bytes<2 || bytes>65536 || unsafe { *name }!=0 { return Err(()); }
    }
    Ok(())
}

fn exclusive_idle_lease(path: &std::path::Path) -> Result<File, ()> {
    let file=std::fs::OpenOptions::new().read(true).write(true).share_mode(3).open(path).map_err(|_|())?;
    let mut overlapped:Overlapped=unsafe { std::mem::zeroed() };
    if unsafe { LockFileEx(file.as_raw_handle(),3,0,1,0,&mut overlapped) }==0 { return Err(()); }
    Ok(file)
}

fn seal_current(request:Request) -> Result<serde_json::Value, ()> {
    if !installed_admin() || !valid_id(&request.expected_native_id) || !valid_nonce(&request.nonce) { return Err(()); }
    let key=hex::decode(&request.recipient_public_key).map_err(|_|())?;
    let recipient=box_::PublicKey::from_slice(&key).ok_or(())?;
    let path=std::env::current_exe().map_err(|_|())?.with_file_name(crate::g3_update_gate::FILE_NAME);
    let _lease=exclusive_idle_lease(&path)?;
    let _sibling=crate::platform::g3_shared_host::sibling_gate().map(|p|exclusive_idle_lease(&p)).transpose()?;
    unoccupied()?;
    let id=crate::ipc::get_config("id").map_err(|_|())?.ok_or(())?;
    if id!=request.expected_native_id { return Err(()); }
    // Existing main-IPC executable, elevation and session authorization stays intact.
    let password=crate::ipc::get_config("temporary-password").map_err(|_|())?.ok_or(())?;
    let issued=now()?;
    let payload=Payload { purpose:PURPOSE.into(), native_id:id.clone(), nonce:request.nonce.clone(), issued_at:issued, expires_at:issued+30, password };
    if payload.password.is_empty() || payload.password.len()>128 || payload.password.chars().any(char::is_control) { return Err(()); }
    unoccupied()?;
    let mut plain=serde_json::to_vec(&payload).map_err(|_|())?;
    let cipher=sealedbox::seal(&plain,&recipient);plain.fill(0);
    Ok(serde_json::json!({"ok":true,"nativeId":id,"nonce":request.nonce,"ciphertext":hex::encode(cipher)}))
}

pub(crate) fn run_cli() -> ! {
    std::thread::spawn(|| { std::thread::sleep(Duration::from_secs(20)); std::process::exit(2); });
    let result=(|| {
        let mut bytes=Vec::new();std::io::stdin().take(4097).read_to_end(&mut bytes).map_err(|_|())?;
        if bytes.len()>4096 { return Err(()); }
        let request=serde_json::from_slice(&bytes).map_err(|_|())?;
        seal_current(request)
    })();
    match result {
        Ok(value)=> { println!("{}",value);std::process::exit(0); }
        Err(())=> { println!("{{\"ok\":false,\"status\":\"otp-handoff-unavailable-no-retry\"}}");std::process::exit(2); }
    }
}

fn begin(value:serde_json::Value) -> Result<serde_json::Value, ()> {
    if !installed_admin() { return Err(()); }
    unoccupied()?;
    let id=value["expectedNativeId"].as_str().filter(|s|valid_id(s)).ok_or(())?;
    let nonce=value["nonce"].as_str().filter(|s|valid_nonce(s)).ok_or(())?;
    let mut slot=PROBE_KEY.lock().map_err(|_|())?;
    if slot.as_ref().map_or(false,|k|k.created.elapsed()<KEY_TTL) { return Err(()); }
    let (public,secret)=box_::gen_keypair();
    let result=serde_json::json!({"ok":true,"nativeId":id,"nonce":nonce,"recipientPublicKey":hex::encode(public.as_ref())});
    *slot=Some(ProbeKey {public,secret,id:id.into(),nonce:nonce.into(),created:Instant::now()});
    Ok(result)
}

fn open_for(key:ProbeKey,value:serde_json::Value,clock:u64) -> Result<Payload, ()> {
    if key.created.elapsed()>KEY_TTL || value["nativeId"].as_str()!=Some(key.id.as_str()) || value["nonce"].as_str()!=Some(key.nonce.as_str()) { return Err(()); }
    let cipher=value["ciphertext"].as_str().filter(|s|s.len()<=4096).ok_or(())?;
    let cipher=hex::decode(cipher).map_err(|_|())?;
    let mut plain=sealedbox::open(&cipher,&key.public,&key.secret).map_err(|_|())?;
    let parsed=serde_json::from_slice::<Payload>(&plain);plain.fill(0);
    let payload=parsed.map_err(|_|())?;
    if payload.purpose!=PURPOSE || payload.native_id!=key.id || payload.nonce!=key.nonce
        || payload.issued_at>clock.saturating_add(5) || payload.expires_at<clock
        || payload.expires_at!=payload.issued_at.saturating_add(30)
        || payload.password.is_empty() || payload.password.len()>128 { return Err(()); }
    Ok(payload)
}

fn open(value:serde_json::Value) -> Result<serde_json::Value, ()> {
    let key=PROBE_KEY.lock().map_err(|_|())?.take().ok_or(())?;
    if !installed_admin() { return Err(()); }
    unoccupied()?;
    let payload=open_for(key,value,now()?)?;
    Ok(serde_json::json!({"ok":true,"password":payload.password}))
}

unsafe fn ffi_call(input:*const c_char, action:fn(serde_json::Value)->Result<serde_json::Value, ()>) -> *mut c_char {
    let result=(|| {
        if input.is_null() { return Err(()); }
        let bytes=CStr::from_ptr(input).to_bytes();if bytes.len()>8192 { return Err(()); }
        action(serde_json::from_slice(bytes).map_err(|_|())?)
    })();
    let mut value=result.unwrap_or_else(|_|serde_json::json!({"ok":false,"status":"otp-handoff-not-verified-no-retry"}));
    let serialized=value.to_string();
    if let Some(serde_json::Value::String(password))=value.get_mut("password") {
        unsafe { password.as_mut_vec().fill(0); }
    }
    CString::new(serialized).map_or(std::ptr::null_mut(),CString::into_raw)
}

#[no_mangle]
pub unsafe extern "C" fn g3_otp_probe_begin(input:*const c_char)->*mut c_char { ffi_call(input,begin) }
#[no_mangle]
pub unsafe extern "C" fn g3_otp_probe_open(input:*const c_char)->*mut c_char { ffi_call(input,open) }
#[no_mangle]
pub unsafe extern "C" fn g3_otp_probe_free(value:*mut c_char) {
    if !value.is_null() { let value=CString::from_raw(value);let mut bytes=value.into_bytes();bytes.fill(0); }
}
#[no_mangle]
pub extern "C" fn g3_otp_probe_cancel() { if let Ok(mut key)=PROBE_KEY.lock() { *key=None; } }

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(id:&str,nonce:&str,expires:u64)->(ProbeKey,serde_json::Value) {
        let (public,secret)=box_::gen_keypair();
        let payload=Payload {purpose:PURPOSE.into(),native_id:id.into(),nonce:nonce.into(),issued_at:100,expires_at:expires,password:"test-otp-only".into()};
        let plain=serde_json::to_vec(&payload).unwrap();
        let value=serde_json::json!({"nativeId":id,"nonce":nonce,"ciphertext":hex::encode(sealedbox::seal(&plain,&public))});
        (ProbeKey {public,secret,id:id.into(),nonce:nonce.into(),created:Instant::now()},value)
    }
    const NONCE:&str="0123456789abcdef0123456789abcdef";
    #[test] fn authenticated_envelope_roundtrip() { let (k,v)=fixture("1931174279",NONCE,130);assert_eq!(open_for(k,v,101).unwrap().password,"test-otp-only"); }
    #[test] fn wrong_target_rejected() {let (k,mut v)=fixture("1931174279",NONCE,130);v["nativeId"]=serde_json::json!("1556646966");assert!(open_for(k,v,101).is_err());}
    #[test] fn wrong_nonce_rejected() {let (k,mut v)=fixture("1931174279",NONCE,130);v["nonce"]=serde_json::json!("ffffffffffffffffffffffffffffffff");assert!(open_for(k,v,101).is_err());}
    #[test] fn expired_envelope_rejected() {let (k,v)=fixture("1931174279",NONCE,130);assert!(open_for(k,v,131).is_err());}
    #[test] fn extended_lifetime_rejected() {let (k,v)=fixture("1931174279",NONCE,160);assert!(open_for(k,v,101).is_err());}
    #[test] fn tampered_ciphertext_rejected() {let (k,mut v)=fixture("1931174279",NONCE,130);v["ciphertext"]=serde_json::json!("00".repeat(96));assert!(open_for(k,v,101).is_err());}
    #[test] fn future_envelope_rejected() {let (k,v)=fixture("1931174279",NONCE,130);assert!(open_for(k,v,90).is_err());}
    #[test] fn wrong_recipient_rejected() {let (_,v)=fixture("1931174279",NONCE,130);let (k,_)=fixture("1931174279",NONCE,130);assert!(open_for(k,v,101).is_err());}
    #[test] fn expired_private_key_rejected() {let (mut k,v)=fixture("1931174279",NONCE,130);k.created=Instant::now()-Duration::from_secs(61);assert!(open_for(k,v,101).is_err());}
}
