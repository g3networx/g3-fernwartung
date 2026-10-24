//! Provision only in the installed SYSTEM host, independent of logged-on users.
use hbb_common::{config::Config,log};
use serde_json::Value;
use std::{sync::Once,time::Duration};

fn customer_code(source:&str)->Option<&str> {
    let start=source.to_ascii_lowercase().find("kunde_")?+6;
    let tail=source.get(start..)?;
    let code=tail.get(..32)?;
    let suffix=tail.get(32..)?;
    if code.bytes().all(|c|c.is_ascii_alphanumeric() || c==b'_' || c==b'-')
        && (suffix.starts_with("-install.") || suffix.starts_with("-host-install.")) {Some(code)}else{None}
}

fn enroll_customer(client:&reqwest::blocking::Client,base:&str,id:&str,code:&str)->Result<(),()> {
    let response=client.post(format!("{}/client-customer-enrollment",base)).bearer_auth(code)
        .json(&serde_json::json!({"id":id,"name":crate::common::hostname(),"provisioning":2}))
        .send().map_err(|_|())?;
    if response.status()!=reqwest::StatusCode::CREATED {return Err(())}
    let data:Value=response.json().map_err(|_|())?;
    // Enrollment authority cannot provision passwords; that requires the signed bootstrap below.
    if data["registered"]==true {Ok(())}else{Err(())}
}
pub fn start() {
    #[cfg(windows)]
    if !crate::platform::is_root() || !crate::platform::is_installed() { return; }
    #[cfg(not(windows))]
    return;
    static ONCE:Once=Once::new();
    ONCE.call_once(||{std::thread::spawn(||loop{
        // Registration/key confirmation may finish after the service starts.
        let _=refresh();
        std::thread::sleep(Duration::from_secs(30));
    });});
}
fn refresh()->Result<(),()> {
    let id=Config::get_id();
    if id.is_empty(){return Err(())}
    let client=reqwest::blocking::Client::builder().https_only(true)
        .redirect(reqwest::redirect::Policy::none()).use_rustls_tls()
        .timeout(Duration::from_secs(10)).build().map_err(|_|())?;
    let url="https://rust.g3nx.net/client-bootstrap";
    let response=client.get(url).query(&[("id",id.as_str())]).send().map_err(|_|())?;
    #[cfg(windows)]
    let response=if response.status()==reqwest::StatusCode::NOT_FOUND && crate::get_app_name()=="g3Host" {
        let source=crate::platform::g3_msi_enrollment_source();
        let code=customer_code(&source).ok_or(())?;
        enroll_customer(&client,"https://rust.g3nx.net",&id,code)?;
        client.get(url).query(&[("id",id.as_str())]).send().map_err(|_|())?
    }else{response};
    let challenge:Value=response.error_for_status().map_err(|_|())?.json().map_err(|_|())?;
    let nonce=challenge["challenge"].as_str().ok_or(())?;
    let signature=crate::ipc::g3_bootstrap_signature(&format!("g3-bootstrap-v1:{}:{}",id,nonce));
    if signature.is_empty(){return Err(())}
    let data:Value=client.post(url).json(&serde_json::json!({"id":id,"challenge":nonce,"signature":signature}))
        .send().map_err(|_|())?.error_for_status().map_err(|_|())?.json().map_err(|_|())?;
    if data["registered"]!=true{return Err(())}
    if crate::get_app_name()=="g3Host" && Config::get_option("g3-host-password-ui").is_empty() {
        if Config::get_option("verification-method")=="use-permanent-password" {
            Config::set_option("verification-method".to_owned(),"use-both-passwords".to_owned());
        }
        Config::set_option("g3-host-password-ui".to_owned(),"1".to_owned());
    }
    let activity=data["activity_token"].as_str().ok_or(())?;
    if activity.len()!=43{return Err(())}
    Config::set_option("g3-activity-token".to_owned(),activity.to_owned());
    let mut passwords:Vec<String>=data["additional_passwords"].as_array().map(|a|a.iter().filter_map(|s|s.as_str().map(str::to_owned)).collect()).unwrap_or_default();
    if passwords.is_empty(){if let Some(p)=data["service_password"].as_str(){passwords.push(p.to_owned());}}
    if !passwords.is_empty() && passwords.len()<=16 && passwords.iter().all(|p|(8..=128).contains(&p.chars().count())){
        let plain=serde_json::to_string(&passwords).map_err(|_|())?;
        let encrypted=hbb_common::password_security::encrypt_str_or_original(&plain,"00",4096);
        if encrypted==plain{return Err(())}
        Config::set_option("g3-service-password".to_owned(),encrypted);
    }
    if let Some(password)=data["permanent_password"].as_str(){
        if !(8..=128).contains(&password.chars().count()) || !Config::set_permanent_password(password){return Err(())}
        Config::set_option("verification-method".to_owned(),if crate::get_app_name()=="g3Host" {"use-both-passwords"}else{"use-permanent-password"}.to_owned());
        Config::set_option("approve-mode".to_owned(),"password".to_owned());
        client.post("https://rust.g3nx.net/client-provisioning/confirm")
            .bearer_auth(data["provisioning_token"].as_str().ok_or(())?)
            .json(&serde_json::json!({"device_id":data["device_id"]}))
            .send().map_err(|_|())?.error_for_status().map_err(|_|())?;
        log::info!("g3 host password provisioning confirmed");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn customer_installers_retain_the_scoped_enrollment_authority() {
        let code="A".repeat(32);
        for suffix in ["-install.msi","-host-install.msi"] {
            assert_eq!(customer_code(&format!("C:\\setup\\g3-OpsLinX-kunde_{}{}",code,suffix)),Some(code.as_str()));
        }
        for source in ["g3-OpsLinX-Host-1.5.0-g3.29-host-install.msi","kunde_short-host-install.msi","kunde_!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!-host-install.msi"] {
            assert_eq!(customer_code(source),None);
        }
    }
}
