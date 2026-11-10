pub fn skip_inferred_rustdesk_api(app_name: &str, api: &str) -> bool {
    api.is_empty() && matches!(app_name, "g3Fernwartung" | "g3Host" | "g3Soforthilfe")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opslinx_does_not_infer_the_unused_port_21114_api() {
        for app in ["g3Fernwartung", "g3Host", "g3Soforthilfe"] {
            assert!(skip_inferred_rustdesk_api(app, ""));
            assert!(!skip_inferred_rustdesk_api(app, "https://api.example.test"));
        }
    }

    #[test]
    fn upstream_and_other_custom_clients_keep_their_existing_api_path() {
        for app in ["RustDesk", "OtherClient"] {
            assert!(!skip_inferred_rustdesk_api(app, ""));
        }
    }
}
