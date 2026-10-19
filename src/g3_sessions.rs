//! Native admission and durable accounting; independent of connection-manager UI.
use hbb_common::config::Config;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, sync::{Arc, atomic::{AtomicBool, Ordering}}, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};
fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() }
fn folder() -> PathBuf { Config::file().parent().unwrap().join("g3-session-journal") }
#[derive(Clone, Serialize, Deserialize)]
struct Record { event:String, sequence:u64, started:u64, elapsed:u64, closed:bool, interrupted:bool, peer_id:String, kind:String, pid:u32 }
fn store(r:&Record) -> bool {
    let dir=folder(); if std::fs::create_dir_all(&dir).is_err(){return false;}
    let path=dir.join(format!("{}.json",r.event));let tmp=path.with_extension("tmp");
    use std::io::Write;
    let result=(|| -> std::io::Result<()> {let mut f=std::fs::File::create(&tmp)?;f.write_all(&serde_json::to_vec(r)?)?;f.sync_all()?;drop(f);replace(&tmp,&path)})();
    result.is_ok()
}
#[cfg(windows)]
fn replace(a:&std::path::Path,b:&std::path::Path)->std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    #[link(name="kernel32")] extern "system" {fn MoveFileExW(a:*const u16,b:*const u16,flags:u32)->i32;}
    let a:Vec<u16>=a.as_os_str().encode_wide().chain(Some(0)).collect();let b:Vec<u16>=b.as_os_str().encode_wide().chain(Some(0)).collect();
    if unsafe{MoveFileExW(a.as_ptr(),b.as_ptr(),9)}==0{Err(std::io::Error::last_os_error())}else{Ok(())}
}
#[cfg(not(windows))]
fn replace(a:&std::path::Path,b:&std::path::Path)->std::io::Result<()> {std::fs::rename(a,b)}
#[cfg(windows)]
fn alive(pid:u32)->bool {
    use std::ffi::c_void;
    #[link(name="kernel32")] extern "system" {fn OpenProcess(access:u32,inherit:i32,pid:u32)->*mut c_void;fn WaitForSingleObject(h:*mut c_void,ms:u32)->u32;fn CloseHandle(h:*mut c_void)->i32;fn GetLastError()->u32;}
    unsafe {let h=OpenProcess(0x100000,0,pid);if h.is_null(){return GetLastError()==5;}let state=WaitForSingleObject(h,0);CloseHandle(h);state!=0}
}
#[cfg(not(windows))]
fn alive(pid:u32)->bool {std::path::Path::new(&format!("/proc/{pid}")).exists()}
fn http()->Option<reqwest::blocking::Client> {reqwest::blocking::Client::builder().https_only(true).redirect(reqwest::redirect::Policy::none()).use_rustls_tls().timeout(Duration::from_secs(4)).build().ok()}
fn lease(c:&reqwest::blocking::Client,event:&str,op:&str,key:&str)->Result<bool,()> {
    let r=c.post("https://rust.g3nx.net/client-session").bearer_auth(key).json(&serde_json::json!({"event":event,"operation":op})).send().map_err(|_|())?;
    if r.status().as_u16()==409{return Ok(false)}
    if !r.status().is_success(){return Err(())} Ok(r.json::<serde_json::Value>().map_err(|_|())?["allowed"]==true)
}
fn report(c:&reqwest::blocking::Client,r:&Record,key:&str)->bool {c.post("https://rust.g3nx.net/client-activity").bearer_auth(key).json(r).send().map(|r|r.status().is_success()).unwrap_or(false)}
pub struct Session { stop:Arc<AtomicBool>, valid:Arc<AtomicBool> }
impl Session {
    pub fn valid(&self)->bool {self.valid.load(Ordering::SeqCst)}
    pub fn close(&self){self.stop.store(true,Ordering::SeqCst);}
    pub async fn start(peer:String,kind:&str)->Result<Self,&'static str> {
        let event=uuid::Uuid::new_v4().simple().to_string();let key=Config::get_option("g3-activity-token");
        if !key.is_empty() {
            let c=reqwest::Client::builder().https_only(true).redirect(reqwest::redirect::Policy::none()).use_rustls_tls().timeout(Duration::from_secs(4)).build().map_err(|_|"Session admission unavailable")?;
            let r=c.post("https://rust.g3nx.net/client-session").bearer_auth(&key).json(&serde_json::json!({"event":event,"operation":"acquire"})).send().await.map_err(|_|"Session admission unavailable")?;
            if r.status().as_u16()==409{return Err("Customer session limit reached")}
            if !r.status().is_success() || r.json::<serde_json::Value>().await.map_err(|_|"Session admission unavailable")?["allowed"]!=true{return Err("Session admission unavailable")}
        }
        let mut r=Record{event,sequence:0,started:now(),elapsed:0,closed:false,interrupted:false,peer_id:peer,kind:kind.to_owned(),pid:std::process::id()};
        if !store(&r){return Err("Session journal unavailable")}
        let stop=Arc::new(AtomicBool::new(false));let valid=Arc::new(AtomicBool::new(true));let s=stop.clone();let v=valid.clone();
        std::thread::spawn(move||{
            let clock=Instant::now();let mut last_ok=Instant::now();let mut last_send=Instant::now()-Duration::from_secs(30);let c=http();
            loop {
                r.elapsed=clock.elapsed().as_secs();r.sequence+=1;r.closed=s.load(Ordering::SeqCst);
                if !store(&r){v.store(false,Ordering::SeqCst);break;}
                let key=Config::get_option("g3-activity-token");
                if let Some(c)=c.as_ref(){if !key.is_empty() && (r.closed || last_send.elapsed()>=Duration::from_secs(20)) {
                    last_send=Instant::now();
                    if r.closed {let _=lease(c,&r.event,"end",&key);} else {match lease(c,&r.event,"pulse",&key){Ok(true)=>last_ok=Instant::now(),Ok(false)=>{v.store(false,Ordering::SeqCst);},Err(_)=>{if last_ok.elapsed()>=Duration::from_secs(75){v.store(false,Ordering::SeqCst);}}}}
                    if report(c,&r,&key) && r.closed {let _=std::fs::remove_file(folder().join(format!("{}.json",r.event)));}
                }}
                if r.closed{break;}std::thread::sleep(Duration::from_secs(1));
            }
        });
        Ok(Self{stop,valid})
    }
}
impl Drop for Session {fn drop(&mut self){self.close();}}
pub fn recovery() {
    static ONCE:std::sync::Once=std::sync::Once::new();
    ONCE.call_once(||{std::thread::spawn(||loop{
        if let Some(c)=http(){let key=Config::get_option("g3-activity-token");if !key.is_empty(){
            if let Ok(files)=std::fs::read_dir(folder()){for file in files.flatten(){let path=file.path();if path.extension().and_then(|x|x.to_str())!=Some("json"){continue;}
                let mut r:Record=match std::fs::read(&path).ok().and_then(|b|serde_json::from_slice(&b).ok()){Some(r)=>r,None=>continue};
                if !r.closed && alive(r.pid){continue;}
                if !r.closed {r.closed=true;r.interrupted=true;r.sequence+=1;if !store(&r){continue;}}
                let _=lease(&c,&r.event,"end",&key);if report(&c,&r,&key){let _=std::fs::remove_file(path);}
            }}
        }}std::thread::sleep(Duration::from_secs(30));
    });});
}
