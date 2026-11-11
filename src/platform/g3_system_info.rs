use std::ptr;

#[link(name = "netapi32")]
extern "system" {
    fn NetGetJoinInformation(server: *const u16, name: *mut *mut u16, status: *mut u32) -> u32;
    fn NetApiBufferFree(buffer: *mut std::ffi::c_void) -> u32;
}

pub(crate) fn computer_domain() -> Option<String> {
    let mut name = ptr::null_mut();
    let mut status = 0;
    let result = unsafe { NetGetJoinInformation(ptr::null(), &mut name, &mut status) };
    if name.is_null() {
        return None;
    }
    let domain = if result == 0 && status == 3 {
        let mut len = 0;
        while unsafe { *name.add(len) } != 0 {
            len += 1;
        }
        Some(String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(name, len) }))
    } else {
        None
    };
    unsafe { NetApiBufferFree(name.cast()) };
    domain
}
