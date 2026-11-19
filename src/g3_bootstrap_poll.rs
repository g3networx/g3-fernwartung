pub(super) fn delay(failures: u32, random: u32) -> u64 {
    let seconds = if failures == 0 { 300 } else { (30u64 << failures.min(6).saturating_sub(1)).min(900) };
    seconds * 4 / 5 + u64::from(random) % (seconds * 2 / 5 + 1)
}

#[cfg(test)]
mod tests {
    use super::delay;

    #[test]
    fn successful_heartbeats_are_spread_over_four_to_six_minutes() {
        for random in 0..1000 {
            assert!((240..=360).contains(&delay(0, random)));
        }
    }

    #[test]
    fn failures_back_off_without_overflow_and_success_resets_the_delay() {
        assert_eq!(delay(1, 0), 24);
        assert_eq!(delay(2, 0), 48);
        assert_eq!(delay(3, 0), 96);
        assert_eq!(delay(u32::MAX, 0), 720);
        assert_eq!(delay(0, 0), 240);
    }
}
