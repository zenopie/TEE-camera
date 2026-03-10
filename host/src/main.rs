//! host – Keystone enclave host runner for TEE-camera frame signing.
//!
//! Usage:
//!   host --enclave <eapp.eapp> --runtime <eyrie-rt> \
//!        --frames <count> --width <w> --height <h> \
//!        --fps <fps> --output <dir>
//!
//! The host:
//!  1. Loads and starts the Keystone enclave via a thin C wrapper.
//!  2. Obtains the untrusted shared-memory region (SharedMem).
//!  3. Iterates over <count> synthetic frames, writes each into shm.frame_data,
//!     sets the control fields, issues CMD_SIGN, then spin-waits for STATUS_DONE.
//!  4. Writes each SignedFrame as a binary file: <output>/frame_NNNNNN.sig
//!  5. Prints a summary when finished.

use std::ffi::CString;
use std::os::raw::{c_char, c_int, c_void};
use std::path::Path;
use std::ptr;
use std::sync::atomic::{fence, Ordering};
use std::thread;
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Constants – must match enclave/common.h
// ---------------------------------------------------------------------------

const FRAME_MAX_BYTES: usize = 1920 * 1080 * 3;

const CMD_NOP: u32    = 0;
const CMD_SIGN: u32   = 1;

const STATUS_IDLE: u32  = 0;
const STATUS_BUSY: u32  = 1;
const STATUS_DONE: u32  = 2;
const STATUS_ERROR: u32 = 3;

const FORMAT_SYNTHETIC: u32 = 2;

// ---------------------------------------------------------------------------
// C-compatible structs – layout must be identical to common.h
// ---------------------------------------------------------------------------

#[derive(Copy, Clone)]
#[repr(C)]
struct SignedFrame {
    sequence:     u64,
    monotonic_ts: u64,
    frame_hash:   [u8; 32],
    sig:          [u8; 64],
    pubkey:       [u8; 32],
    width:        u32,
    height:       u32,
    format:       u32,
    frame_size:   u32,
}

#[repr(C)]
struct SharedMem {
    cmd:        u32,
    status:     u32,
    frame_size: u32,
    width:      u32,
    height:     u32,
    format:     u32,
    result:     SignedFrame,
    frame_data: [u8; FRAME_MAX_BYTES],
}

// ---------------------------------------------------------------------------
// FFI declarations for keystone_wrapper.cpp
// ---------------------------------------------------------------------------

#[allow(non_camel_case_types)]
enum OpaqueKeystone {}

extern "C" {
    fn keystone_create(
        enclave_path:   *const c_char,
        runtime_path:   *const c_char,
        free_mem_size:  usize,
        untrusted_size: usize,
    ) -> *mut OpaqueKeystone;

    fn keystone_destroy(h: *mut OpaqueKeystone);

    fn keystone_get_shared_buffer(h: *mut OpaqueKeystone) -> *mut c_void;

    fn keystone_run(h: *mut OpaqueKeystone) -> c_int;
}

// Newtype so the raw pointer can cross thread boundaries.
struct SendPtr(*mut OpaqueKeystone);
unsafe impl Send for SendPtr {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn ensure_dir(path: &Path) -> Result<(), String> {
    if path.exists() {
        if path.is_dir() {
            return Ok(());
        }
        return Err(format!("'{}' exists but is not a directory", path.display()));
    }
    std::fs::create_dir_all(path)
        .map_err(|e| format!("cannot create directory '{}': {}", path.display(), e))
}

/// Synthetic frame N: byte at position i = (i + N) mod 256.
fn generate_frame(buf: &mut [u8], frame_n: u64) {
    for (i, b) in buf.iter_mut().enumerate() {
        *b = ((i as u64).wrapping_add(frame_n) & 0xFF) as u8;
    }
}

fn write_signed_frame(output_dir: &Path, seq: u64, sf: &SignedFrame) -> Result<(), String> {
    let path = output_dir.join(format!("frame_{:06}.sig", seq));
    let bytes = unsafe {
        std::slice::from_raw_parts(
            sf as *const SignedFrame as *const u8,
            std::mem::size_of::<SignedFrame>(),
        )
    };
    std::fs::write(&path, bytes)
        .map_err(|e| format!("cannot write '{}': {}", path.display(), e))
}

fn usage(prog: &str) {
    eprintln!(
        "Usage: {prog} --enclave <path> --runtime <path>\n\
         \x20         --frames <count> --width <w> --height <h>\n\
         \x20         --fps <fps> --output <dir>"
    );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let prog = args.first().map(String::as_str).unwrap_or("host");

    let mut enclave_path: Option<String> = None;
    let mut runtime_path: Option<String> = None;
    let mut output_dir:   Option<String> = None;
    let mut frames: i64 = 1;
    let mut width:  i64 = 640;
    let mut height: i64 = 480;
    let mut fps:    i64 = 30;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--enclave" if i + 1 < args.len() => { i += 1; enclave_path = Some(args[i].clone()); }
            "--runtime" if i + 1 < args.len() => { i += 1; runtime_path = Some(args[i].clone()); }
            "--frames"  if i + 1 < args.len() => { i += 1; frames = args[i].parse().unwrap_or(1); }
            "--width"   if i + 1 < args.len() => { i += 1; width  = args[i].parse().unwrap_or(640); }
            "--height"  if i + 1 < args.len() => { i += 1; height = args[i].parse().unwrap_or(480); }
            "--fps"     if i + 1 < args.len() => { i += 1; fps    = args[i].parse().unwrap_or(30); }
            "--output"  if i + 1 < args.len() => { i += 1; output_dir = Some(args[i].clone()); }
            arg => {
                eprintln!("Unknown argument: {}", arg);
                usage(prog);
                std::process::exit(1);
            }
        }
        i += 1;
    }

    let (Some(enclave_path), Some(runtime_path), Some(output_dir)) =
        (enclave_path, runtime_path, output_dir)
    else {
        usage(prog);
        std::process::exit(1);
    };

    if frames <= 0 || width <= 0 || height <= 0 || fps <= 0 {
        eprintln!("Error: frames, width, height, fps must be positive");
        std::process::exit(1);
    }

    let frame_width  = width  as u32;
    let frame_height = height as u32;
    let frame_size   = frame_width as usize * frame_height as usize * 3; // RGB

    if frame_size > FRAME_MAX_BYTES {
        eprintln!(
            "Error: frame size {} exceeds FRAME_MAX_BYTES ({})",
            frame_size, FRAME_MAX_BYTES
        );
        std::process::exit(1);
    }

    let output_path = Path::new(&output_dir);
    if let Err(e) = ensure_dir(output_path) {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }

    // ---- Configure and start enclave ----

    let shm_size  = std::mem::size_of::<SharedMem>();
    let shm_pages = ((shm_size + 4095) / 4096).max(1);

    let enc_cstr = CString::new(enclave_path).expect("invalid enclave path");
    let rt_cstr  = CString::new(runtime_path).expect("invalid runtime path");

    let enc = unsafe {
        keystone_create(
            enc_cstr.as_ptr(),
            rt_cstr.as_ptr(),
            16 * 1024 * 1024,   // 16 MB free mem
            shm_pages * 4096,
        )
    };
    if enc.is_null() {
        eprintln!("Error: keystone_create failed");
        std::process::exit(1);
    }

    let shm_raw = unsafe { keystone_get_shared_buffer(enc) };
    if shm_raw.is_null() {
        eprintln!("Error: getSharedBuffer returned NULL");
        unsafe { keystone_destroy(enc) };
        std::process::exit(1);
    }
    let shm: *mut SharedMem = shm_raw as *mut SharedMem;

    // Initialise shared region.
    unsafe {
        ptr::write_bytes(shm as *mut u8, 0, std::mem::size_of::<SharedMem>());
        ptr::write_volatile(ptr::addr_of_mut!((*shm).cmd),    CMD_NOP);
        ptr::write_volatile(ptr::addr_of_mut!((*shm).status), STATUS_IDLE);
    }

    // Run the enclave in a background thread; it blocks inside keystone_run
    // until the enclave exits.
    let enc_for_thread = SendPtr(enc);
    let enclave_thread = thread::spawn(move || unsafe { keystone_run(enc_for_thread.0) });

    // Brief spin to let the enclave reach its idle loop (up to 5 s).
    let boot_deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let status = unsafe { ptr::read_volatile(ptr::addr_of!((*shm).status)) };
        if status == STATUS_IDLE || Instant::now() >= boot_deadline {
            break;
        }
        thread::sleep(Duration::from_millis(1));
    }

    // ---- Frame loop ----

    let frame_interval = if fps > 0 {
        Duration::from_secs_f64(1.0 / fps as f64)
    } else {
        Duration::ZERO
    };

    let start        = Instant::now();
    let mut deadline = start;
    let mut errors: i64 = 0;

    for n in 0i64..frames {
        deadline += frame_interval;

        // Generate synthetic frame directly into shared-memory frame_data.
        let frame_slice = unsafe {
            std::slice::from_raw_parts_mut(
                ptr::addr_of_mut!((*shm).frame_data) as *mut u8,
                frame_size,
            )
        };
        generate_frame(frame_slice, n as u64);

        // Write control metadata.
        unsafe {
            ptr::write_volatile(ptr::addr_of_mut!((*shm).frame_size), frame_size as u32);
            ptr::write_volatile(ptr::addr_of_mut!((*shm).width),      frame_width);
            ptr::write_volatile(ptr::addr_of_mut!((*shm).height),     frame_height);
            ptr::write_volatile(ptr::addr_of_mut!((*shm).format),     FORMAT_SYNTHETIC);
            ptr::write_volatile(ptr::addr_of_mut!((*shm).status),     STATUS_IDLE);
        }

        // Full barrier then issue the sign command.
        fence(Ordering::SeqCst);
        unsafe { ptr::write_volatile(ptr::addr_of_mut!((*shm).cmd), CMD_SIGN) };
        fence(Ordering::SeqCst);

        // Spin-wait for the enclave to finish.
        let status = loop {
            fence(Ordering::Acquire);
            let s = unsafe { ptr::read_volatile(ptr::addr_of!((*shm).status)) };
            if s != STATUS_IDLE && s != STATUS_BUSY {
                break s;
            }
        };

        if status == STATUS_ERROR {
            eprintln!("Frame {}: enclave returned STATUS_ERROR", n);
            errors += 1;
            unsafe {
                ptr::write_volatile(ptr::addr_of_mut!((*shm).cmd),    CMD_NOP);
                ptr::write_volatile(ptr::addr_of_mut!((*shm).status), STATUS_IDLE);
            }
            continue;
        }

        // STATUS_DONE – copy SignedFrame out of shared memory.
        let sf = unsafe { ptr::read(ptr::addr_of!((*shm).result)) };

        // Reset for the next frame.
        unsafe {
            ptr::write_volatile(ptr::addr_of_mut!((*shm).cmd),    CMD_NOP);
            ptr::write_volatile(ptr::addr_of_mut!((*shm).status), STATUS_IDLE);
        }

        if let Err(e) = write_signed_frame(output_path, n as u64, &sf) {
            eprintln!("Frame {}: {}", n, e);
            errors += 1;
        }

        // Rate-limit to requested FPS.
        let now = Instant::now();
        if deadline > now {
            thread::sleep(deadline - now);
        }

        if (n + 1) % 100 == 0 || n == frames - 1 {
            print!("Processed {} / {} frames\r", n + 1, frames);
            use std::io::Write as _;
            let _ = std::io::stdout().flush();
        }
    }

    // Signal the enclave to exit.
    fence(Ordering::SeqCst);
    unsafe { ptr::write_volatile(ptr::addr_of_mut!((*shm).cmd), CMD_NOP) };
    fence(Ordering::SeqCst);

    // Wait for the enclave thread.
    let _ = enclave_thread.join();

    // Tear down the enclave handle.
    unsafe { keystone_destroy(enc) };

    // ---- Summary ----
    let elapsed  = start.elapsed().as_secs_f64();
    let achieved = if elapsed > 0.0 { frames as f64 / elapsed } else { 0.0 };

    println!("\n=== Summary ===");
    println!("  Frames requested : {}", frames);
    println!("  Frames processed : {}", frames - errors);
    println!("  Errors           : {}", errors);
    println!("  Elapsed          : {:.3} s", elapsed);
    println!("  FPS achieved     : {:.2}", achieved);
    println!("  Output directory : {}", output_dir);

    std::process::exit(if errors == 0 { 0 } else { 1 });
}
