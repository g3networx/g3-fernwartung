use std::net::{Ipv4Addr, UdpSocket};
use std::ptr;
use winapi::um::dsrole::{
    DsRoleFreeMemory, DsRoleGetPrimaryDomainInformation, DsRolePrimaryDomainInfoBasic,
    DSROLE_PRIMARY_DOMAIN_INFO_BASIC,
};

pub(crate) fn primary_ipv4() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    // Select the local address for the default IPv4 route without sending a packet.
    socket.connect((Ipv4Addr::new(1, 1, 1, 1), 9)).ok()?;
    match socket.local_addr().ok()? {
        std::net::SocketAddr::V4(address)
            if !address.ip().is_unspecified() && !address.ip().is_loopback() =>
        {
            Some(*address.ip())
        }
        _ => None,
    }
}

pub(crate) fn computer_domain() -> Option<String> {
    let mut buffer = ptr::null_mut();
    let result = unsafe {
        DsRoleGetPrimaryDomainInformation(ptr::null(), DsRolePrimaryDomainInfoBasic, &mut buffer)
    };
    if buffer.is_null() {
        return None;
    }
    let name = if result == 0 {
        unsafe { (*buffer.cast::<DSROLE_PRIMARY_DOMAIN_INFO_BASIC>()).DomainNameDns }
    } else {
        ptr::null_mut()
    };
    let domain = if !name.is_null() && unsafe { *name } != 0 {
        let mut len = 0;
        while unsafe { *name.add(len) } != 0 {
            len += 1;
        }
        Some(String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(name, len) }))
    } else {
        None
    };
    unsafe { DsRoleFreeMemory(buffer.cast()) };
    domain
}
