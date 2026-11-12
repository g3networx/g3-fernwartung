//! Local safety guard. Machine markers are never authentication credentials.
use std::net::{IpAddr, SocketAddr, UdpSocket};

pub const ERROR: &str = "Verbindungen zum eigenen Rechner sind nicht erlaubt.";

pub fn same_machine(local: &[u8], remote: &[u8]) -> bool {
    local.len() == 32 && remote.len() == 32
        && local.iter().zip(remote).fold(0u8, |diff, (a,b)| diff | (a ^ b)) == 0
}

pub fn login_machine_marker(login: &mut base::message_proto::LoginRequest) -> hbb_common::bytes::Bytes {
    if login.g3_machine.is_empty() {
        if !login.trusted_device_v2_supported {
            return std::mem::take(&mut login.trusted_device_v2_token);
        }
        return login.g3_machine.clone();
    }
    if login.g3_machine == login.trusted_device_v2_token {
        // The compatibility copy in field 18 must never enter device authentication.
        login.trusted_device_v2_token.clear();
    }
    login.g3_machine.clone()
}

fn bare_target(target: &str) -> &str {
    let target = target.trim();
    let target = target.strip_prefix("g3fernwartung://")
        .or_else(|| target.strip_prefix("rustdesk://")).unwrap_or(target);
    target.split('?').next().unwrap_or(target).split('@').next().unwrap_or(target)
        .trim_end_matches('/').trim_end_matches("/r")
}

pub fn target_is_self(target: &str, own_ids: &[String]) -> bool {
    let target = bare_target(target);
    if target.is_empty() { return false; }
    if own_ids.iter().any(|id| !id.is_empty() && target == id) { return true; }
    let host = target.split_once(':').map(|x|x.0).unwrap_or(target);
    if host.eq_ignore_ascii_case("localhost") { return true; }
    let ip = target.parse::<IpAddr>().ok()
        .or_else(|| target.parse::<SocketAddr>().ok().map(|x|x.ip()));
    if let Some(ip) = ip {
        if ip.is_loopback() || ip.is_unspecified() { return true; }
        if let IpAddr::V6(v6) = ip {
            if v6.to_ipv4_mapped().map_or(false, |v4|v4.is_loopback() || v4.is_unspecified()) { return true; }
        }
        // UDP connect chooses a route without sending a packet. Local interface
        // addresses select themselves; a different host behind the same NAT does not.
        let bind = if ip.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
        if let Ok(socket) = UdpSocket::bind(bind) {
            if socket.connect(SocketAddr::new(ip,9)).is_ok()
                && socket.local_addr().map_or(false, |local|local.ip()==ip) { return true; }
        }
    }
    false
}

#[cfg(test)]
mod tests {
 use super::*;
 #[test] fn same_host_across_variants_and_sessions() {
  assert!(same_machine(&[17;32], &[17;32]));
  assert!(!same_machine(&[17;32], &[18;32]));
  assert!(!same_machine(&[], &[]));
  assert!(!same_machine(&[17;31], &[17;31]));
 }
 #[test] fn login_marker_keeps_legacy_peers_and_trusted_tokens_separate() {
  use base::message_proto::LoginRequest;
  let marker = hbb_common::bytes::Bytes::from_static(&[17; 32]);
  let token = hbb_common::bytes::Bytes::from_static(&[18; 32]);
  let mut legacy = LoginRequest {
   trusted_device_v2_token: marker.clone(),
   ..Default::default()
  };
  assert_eq!(login_machine_marker(&mut legacy), marker);
  assert!(legacy.trusted_device_v2_token.is_empty());
  let mut compatibility = LoginRequest {
   g3_machine: marker.clone(),
   trusted_device_v2_token: marker.clone(),
   trusted_device_v2_supported: true,
   ..Default::default()
  };
  assert_eq!(login_machine_marker(&mut compatibility), marker);
  assert!(compatibility.trusted_device_v2_token.is_empty());
  compatibility.trusted_device_v2_token = token.clone();
  assert_eq!(login_machine_marker(&mut compatibility), marker);
  assert_eq!(compatibility.trusted_device_v2_token, token);
  compatibility.g3_machine.clear();
  assert!(login_machine_marker(&mut compatibility).is_empty());
  assert_eq!(compatibility.trusted_device_v2_token, token);
 }
 #[test] fn own_id_and_launch_routes() {
  let ids=vec!["100001".into(),"100002".into()];
  for target in ["100001","100002/r","g3fernwartung://100002/","100001@rust.g3nx.net?key=x"] {
   assert!(target_is_self(target,&ids),"{}",target);
  }
  assert!(!target_is_self("200003",&ids));
  assert!(!target_is_self("",&[String::new()]));
 }
 #[test] fn loopback_and_localhost() {
  for target in ["127.0.0.1","127.9.8.7:21118","::1","[::1]:21118","::ffff:127.0.0.1","localhost:21118","0.0.0.0"] {
   assert!(target_is_self(target,&[]),"{}",target);
  }
  assert!(!target_is_self("192.0.2.77",&[]));
 }
}
