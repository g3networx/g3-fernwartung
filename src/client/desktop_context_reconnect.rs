use std::{
    io::ErrorKind,
    time::{Duration, Instant},
};

// Windows may move between the sign-in, RDP and console desktops in several
// steps, each of which can restart the capture process and close the socket.
const GRACE_PERIOD: Duration = Duration::from_secs(45);
const RETRY_INTERVAL: Duration = Duration::from_secs(90);

#[derive(Default)]
pub(super) struct DesktopContextReconnect {
    started_at: Option<Instant>,
}

impl DesktopContextReconnect {
    pub(super) fn should_retry(
        &mut self,
        now: Instant,
        authenticated_desktop: bool,
        error: Option<ErrorKind>,
    ) -> bool {
        if !is_transport_close(error) {
            return false;
        }
        if self.active(now) {
            return true;
        }
        if !authenticated_desktop {
            return false;
        }
        if let Some(started_at) = self.started_at {
            if now.duration_since(started_at) < RETRY_INTERVAL {
                return false;
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

fn is_transport_close(error: Option<ErrorKind>) -> bool {
    matches!(
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
        assert!(retry.should_retry(start, true, Some(ErrorKind::ConnectionReset)));
        assert!(retry.should_retry(start + Duration::from_secs(20), true, None));
        assert!(retry.should_retry(start + GRACE_PERIOD - Duration::from_secs(1), false, None));
        assert!(!retry.should_retry(start + GRACE_PERIOD, true, None));
        assert!(retry.should_retry(start + RETRY_INTERVAL, true, None));
    }

    #[test]
    fn a_retry_round_can_recover_before_its_first_frame() {
        let mut retry = DesktopContextReconnect::default();
        let start = Instant::now();
        assert!(!retry.should_retry(start, false, None));
        assert!(!retry.should_retry(start, true, Some(ErrorKind::PermissionDenied)));
        assert!(retry.should_retry(start, true, Some(ErrorKind::ConnectionReset)));
        assert!(retry.should_retry(start + Duration::from_secs(3), false, None));
        assert!(!retry.should_retry(start + Duration::from_secs(4), false, Some(ErrorKind::PermissionDenied)));
        assert!(!retry.should_retry(start + RETRY_INTERVAL, false, None));
    }
}
