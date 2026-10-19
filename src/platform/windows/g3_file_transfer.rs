fn service_identity(
    app: &str,
    installed: bool,
    system: bool,
    enrolled: bool,
    permanent_password: bool,
    account: String,
) -> Option<String> {
    if matches!(app, "g3Host" | "g3Fernwartung")
        && installed
        && system
        && enrolled
        && permanent_password
        && !account.is_empty()
    {
        Some(account)
    } else {
        None
    }
}

pub(crate) fn authenticated_service_identity(permanent_password: bool) -> Option<String> {
    service_identity(
        &crate::get_app_name(),
        super::is_installed(),
        super::is_root(),
        !hbb_common::config::Config::get_option("g3-activity-token").is_empty(),
        permanent_password,
        crate::username(),
    )
}

#[cfg(test)]
mod tests {
    use super::service_identity;

    #[test]
    fn enrolled_service_reports_its_real_account() {
        assert_eq!(service_identity("g3Host", true, true, true, true, "SYSTEM".into()), Some("SYSTEM".into()));
    }

    #[test]
    fn temporary_password_and_unenrolled_service_keep_prelogin_restriction() {
        assert_eq!(service_identity("g3Host", true, true, true, false, "SYSTEM".into()), None);
        assert_eq!(service_identity("g3Host", true, true, false, true, "SYSTEM".into()), None);
    }

    #[test]
    fn portable_and_user_processes_keep_prelogin_restriction() {
        assert_eq!(service_identity("g3Host", false, true, true, true, "SYSTEM".into()), None);
        assert_eq!(service_identity("g3Host", true, false, true, true, "user".into()), None);
        assert_eq!(service_identity("RustDesk", true, true, true, true, "SYSTEM".into()), None);
    }
}
