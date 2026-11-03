use std::collections::HashMap;
pub fn apply(options:&mut HashMap<String,String>,value:&str)->Result<(), &'static str>{
 let action:serde_json::Value=serde_json::from_str(value).map_err(|_|"Invalid password action")?;
            let current = options.get("g3-local-passwords").cloned().unwrap_or_default();
            let (json, decrypted, _) = hbb_common::password_security::decrypt_str_or_original(&current, "00");
            let mut passwords: Vec<(String, String)> = if current.is_empty() { Vec::new() }
            else if decrypted { serde_json::from_str(&json).map_err(|_|"Existing password storage is invalid")? }
            else { return Err("Existing password storage is unreadable"); };
            if passwords.len() > 16 || passwords.iter().any(|(label,password)| label.is_empty() || label.len()>80 || !(8..=128).contains(&password.chars().count())) {
                return Err("Existing password storage is invalid");
            }
            let label = action["label"].as_str().unwrap_or_default().trim();
            if label.is_empty() || label.len() > 80 { return Err("Invalid password action"); }
            match action["action"].as_str() {
                Some("add") => {
                    let password = action["password"].as_str().unwrap_or_default();
                    if password.chars().count() < 8 || password.chars().count() > 128 || passwords.len() >= 16 || passwords.iter().any(|(l,_)| l == label) { return Err("Invalid password action"); }
                    passwords.push((label.to_owned(), password.to_owned()));
                }
                Some("remove") => passwords.retain(|(l,_)| l != label),
                _ => return Err("Invalid password action"),
            }
            let json = serde_json::to_string(&passwords).unwrap_or_default();
            let encrypted = hbb_common::password_security::encrypt_str_or_original(&json, "00", 8192);
            if encrypted == json { return Err("Invalid password action"); }
            options.insert("g3-local-passwords".to_owned(), encrypted);
            options.insert("g3-local-password-labels".to_owned(), serde_json::to_string(&passwords.iter().map(|(l,_)| l).collect::<Vec<_>>()).unwrap_or_default());
            Ok(())

}

/// Check the service roundtrip against the full encrypted payload, not labels alone.
pub fn verified_readback(expected:&HashMap<String,String>,actual:&HashMap<String,String>)->bool {
    ["g3-local-passwords", "g3-local-password-labels"].iter().all(|key|
        expected.get(*key).is_some() && expected.get(*key)==actual.get(*key))
}

#[cfg(test)]
mod tests {
 use super::*;
 #[test]
 fn unreadable_existing_storage_never_becomes_empty() {
  let mut options=HashMap::new();options.insert("g3-local-passwords".into(),"unreadable".into());
  let before=options.clone();
  assert!(apply(&mut options,r#"{"action":"add","label":"new","password":"fixture-password"}"#).is_err());
  assert_eq!(options,before);
 }
 #[test]
 fn matching_labels_do_not_prove_password_persistence() {
  let mut expected=HashMap::new();expected.insert("g3-local-password-labels".into(),"[label]".into());expected.insert("g3-local-passwords".into(),"encrypted-new".into());
  let mut actual=expected.clone();actual.insert("g3-local-passwords".into(),"encrypted-old".into());
  assert!(!verified_readback(&expected,&actual));assert!(verified_readback(&expected,&expected));
 }
 #[test]
 fn encrypted_malformed_storage_is_preserved() {
  let encrypted=hbb_common::password_security::encrypt_str_or_original("not-json","00",8192);
  assert_ne!(encrypted,"not-json");
  let mut options=HashMap::new();options.insert("g3-local-passwords".into(),encrypted);
  let before=options.clone();
  assert!(apply(&mut options,r#"{"action":"add","label":"new","password":"fixture-password"}"#).is_err());
  assert_eq!(options,before);
 }
 #[test]
 fn adding_standard_keeps_existing_custom_password_and_options() {
  let mut options=HashMap::new();options.insert("unrelated".into(),"keep".into());
  apply(&mut options,r#"{"action":"add","label":"custom","password":"custom-fixture"}"#).unwrap();
  apply(&mut options,r#"{"action":"add","label":"OpsLinX Standardkennwort","password":"standard-fixture"}"#).unwrap();
  let (json,decrypted,_)=hbb_common::password_security::decrypt_str_or_original(options.get("g3-local-passwords").unwrap(),"00");
  assert!(decrypted);let entries:Vec<(String,String)>=serde_json::from_str(&json).unwrap();
  assert_eq!(entries.len(),2);assert_eq!(entries[0],("custom".into(),"custom-fixture".into()));
  assert_eq!(entries[1].1,"standard-fixture");assert_eq!(options.get("unrelated").unwrap(),"keep");
  let before=options.clone();
  assert!(apply(&mut options,r#"{"action":"add","label":"custom","password":"replacement-fixture"}"#).is_err());
  assert_eq!(options,before);
 }

}
