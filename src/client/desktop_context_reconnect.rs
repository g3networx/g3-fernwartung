use std::{
    io::ErrorKind,
    time::{Duration, Instant},
};

const GRACE_PERIOD: Duration = Duration::from_secs(12);
const RETRY_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Default)]
pub(super) struct DesktopContextReconnect {
    started_at: Option<Instant>,
}

impl DesktopContextReconnect {
    pub(super) fn start_or_continue(&mut self, now: Instant) -> bool {
        if let Some(started_at) = self.started_at {
            if now.duration_since(started_at) < RETRY_INTERVAL {
                return self.active(now);
            }
        }
        self.started_at = Some(now);
        true
    }

    pub(super) fn active(&self, now: Instant) -> bool {
        self.started_at
            .map_or(false, |start| now.duration_since(start) < GRACE_PERIOD)
    }
}

pub(super) fn eligible(
    platform: &str,
    authenticated_desktop: bool,
    error: Option<ErrorKind>,
) -> bool {
    authenticated_desktop
        && matches!(platform, "Windows" | "Linux")
        && matches!(
            error,
            None | Some(
                ErrorKind::ConnectionReset
                    | ErrorKind::ConnectionAborted
                    | ErrorKind::BrokenPipe
                    | ErrorKind::UnexpectedEof
            )
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_window_is_bounded_even_if_the_peer_keeps_dropping() {
        let mut retry = DesktopContextReconnect::default();
        let start = Instant::now();
        assert!(!retry.active(start));
        assert!(retry.start_or_continue(start));
        assert!(retry.start_or_continue(start + Duration::from_secs(11)));
        assert!(!retry.start_or_continue(start + GRACE_PERIOD));
        assert!(retry.start_or_continue(start + RETRY_INTERVAL));
    }

    #[test]
    fn only_established_windows_and_linux_desktops_retry_transport_shutdown() {
        assert!(eligible("Windows", true, Some(ErrorKind::ConnectionReset)));
        assert!(eligible("Linux", true, None));
        assert!(!eligible("Windows", false, None));
        assert!(!eligible("Windows", true, Some(ErrorKind::PermissionDenied)));
        assert!(!eligible("Android", true, None));
    }
}
