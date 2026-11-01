pub(super) fn logon_user_parts(user: &str) -> (&str, Option<&str>) {
    if let Some((domain, username)) = user.split_once('\\') {
        (username, Some(domain))
    } else {
        // LogonUserW requires a NULL domain for UPN and unqualified names.
        (user, None)
    }
}

#[cfg(test)]
mod tests {
    use super::logon_user_parts;

    #[test]
    fn upn_keeps_the_full_name_and_has_no_separate_domain() {
        assert_eq!(logon_user_parts("Administrator@example.test"), ("Administrator@example.test", None));
    }

    #[test]
    fn qualified_account_keeps_its_explicit_domain() {
        assert_eq!(logon_user_parts(r"EXAMPLE\Administrator"), ("Administrator", Some("EXAMPLE")));
        assert_eq!(logon_user_parts(r".\support"), ("support", Some(".")));
    }

    #[test]
    fn unqualified_account_is_not_used_as_its_own_domain() {
        assert_eq!(logon_user_parts("support"), ("support", None));
    }
}
