//! binderctl: create binder devices via binderfs.
//! Usage: binderctl NAME...   (mounts /dev/binderfs if needed)

use std::ffi::c_void;
use std::fs::{create_dir_all, OpenOptions};
use std::io::Error;
use std::os::unix::io::AsRawFd;
use std::path::Path;

const MOUNTPOINT: &str = "/dev/binderfs";
const BINDER_CTL_ADD: u64 = 0xc108_6201; // _IOWR('b', 1, struct binderfs_device)

#[repr(C)]
struct BinderfsDevice {
    name: [u8; 256],
    major: u32,
    minor: u32,
}

extern "C" {
    fn ioctl(fd: i32, req: u64, ...) -> i32;
    fn mount(src: *const u8, dst: *const u8, fs: *const u8, flags: u64, data: *const c_void) -> i32;
}

fn main() -> Result<(), String> {
    let names: Vec<String> = std::env::args().skip(1).collect();
    if names.is_empty() {
        return Err("usage: binderctl NAME...".into());
    }

    if !Path::new(MOUNTPOINT).join("binder-control").exists() {
        create_dir_all(MOUNTPOINT).map_err(|e| format!("mkdir {MOUNTPOINT}: {e}"))?;
        let rc = unsafe { mount(c"binder".as_ptr().cast(), c"/dev/binderfs".as_ptr().cast(),
                                c"binder".as_ptr().cast(), 0, std::ptr::null()) };
        if rc != 0 {
            return Err(format!("mount binderfs: {}", Error::last_os_error()));
        }
    }

    let ctl = OpenOptions::new().read(true).write(true)
        .open(format!("{MOUNTPOINT}/binder-control"))
        .map_err(|e| format!("open binder-control: {e}"))?;

    for name in names {
        if name.is_empty() || name.len() > 255 || name.contains('/') {
            return Err(format!("{name:?}: invalid name"));
        }
        let mut dev = BinderfsDevice { name: [0; 256], major: 0, minor: 0 };
        dev.name[..name.len()].copy_from_slice(name.as_bytes());
        if unsafe { ioctl(ctl.as_raw_fd(), BINDER_CTL_ADD as _, &mut dev) } != 0 {
            return Err(format!("{name}: {}", Error::last_os_error()));
        }
        println!("{MOUNTPOINT}/{name} {}:{}", dev.major, dev.minor);
    }
    Ok(())
}
