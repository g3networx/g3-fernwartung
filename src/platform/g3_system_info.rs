use std::ptr;
use winapi::um::dsrole::{
    DsRoleFreeMemory, DsRoleGetPrimaryDomainInformation, DsRolePrimaryDomainInfoBasic,
    DSROLE_PRIMARY_DOMAIN_INFO_BASIC,
};

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
