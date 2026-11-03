// Isolated production-module tests: real Windows crypto/ACL APIs, no service/profile/registry writes.
extern crate self as hbb_common;
pub mod config {pub struct Config;impl Config {
 pub fn get_id()->String {"123456789".into()} pub fn get_option(_: &str)->String {String::new()}
 pub fn set_option(_:String,_:String){} pub fn get_options()->std::collections::HashMap<String,String> {Default::default()}
 pub fn set_options(_:std::collections::HashMap<String,String>){}
 pub fn get_local_permanent_password_storage_and_salt()->(String,String) {(String::new(),String::new())}
 pub fn set_permanent_password_storage_for_sync(_:&str,_:&str)->Result<(),()> {Ok(())}
}}
pub mod platform {pub fn is_installed()->bool {false} pub fn is_root()->bool {false}}
pub fn get_app_name()->String {"g3Host".into()}
#[path="../../../src/g3_registry_password.rs"] mod registry;
