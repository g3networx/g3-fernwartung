use std::collections::HashMap;
pub fn apply(options:&mut HashMap<String,String>,value:&str)->Result<(), &'static str>{
 let action:serde_json::Value=serde_json::from_str(value).map_err(|_|"Invalid password action")?;
            let current = options.get("g3-local-passwords").cloned().unwrap_or_default();
            let (json, decrypted, _) = hbb_common::password_security::decrypt_str_or_original(&current, "00");
            let mut passwords: Vec<(String, String)> = if decrypted { serde_json::from_str(&json).unwrap_or_default() } else { Vec::new() };
            let label = action["label"].as_str().unwrap_or_default().trim();
            if label.is_empty() || label.len() > 80 { return Err("Invalid password action"); }
            match action["action"].as_str() {
                Some("add") => {
                    let password = action["password"].as_str().unwrap_or_default();
                    if password.len() < 8 || password.len() > 128 || passwords.len() >= 16 || passwords.iter().any(|(l,_)| l == label) { return Err("Invalid password action"); }
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
