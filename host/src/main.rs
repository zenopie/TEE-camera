//! TEE-Camera Host Program
//!
//! Connects to the FPGA attestation device over serial (USB-UART),
//! receives public key and per-frame signature packets, and verifies
//! Ed25519 signatures in real time.
//!
//! UART protocol (FPGA → host):
//!   Public key packet:  [0xAA] [0x01] [32 bytes encoded pubkey]
//!   Signature packet:   [0xAA] [0x02] [4B frame_num] [64B hash] [64B sig]

use clap::Parser;
use ed25519_dalek::{Signature, VerifyingKey};
use serialport::SerialPortType;
use std::io::Read;
use std::time::{Duration, Instant};

const SYNC_BYTE: u8 = 0xAA;
const PKT_PUBKEY: u8 = 0x01;
const PKT_SIGNATURE: u8 = 0x02;

const PUBKEY_PAYLOAD: usize = 32;
const SIG_PAYLOAD: usize = 4 + 64 + 64; // frame_num + hash + signature

#[derive(Parser)]
#[command(name = "tee-camera-host", about = "TEE-Camera FPGA attestation host")]
struct Args {
    /// Serial port path (e.g., /dev/tty.usbserial-xxx)
    /// If omitted, auto-detects the first USB serial port.
    #[arg(short, long)]
    port: Option<String>,

    /// Baud rate (DAPLink is fixed at 9600)
    #[arg(short, long, default_value_t = 9_600)]
    baud: u32,

    /// Read UART data from a binary file instead of serial port.
    /// Use with simulation output: make sim-camera-multi
    #[arg(short, long)]
    file: Option<String>,

    /// List available serial ports and exit
    #[arg(long)]
    list_ports: bool,
}

fn list_serial_ports() {
    match serialport::available_ports() {
        Ok(ports) if ports.is_empty() => {
            eprintln!("No serial ports found.");
        }
        Ok(ports) => {
            println!("Available serial ports:");
            for p in &ports {
                let desc = match &p.port_type {
                    SerialPortType::UsbPort(info) => {
                        format!(
                            "USB — {}{}",
                            info.manufacturer.as_deref().unwrap_or("unknown"),
                            info.product
                                .as_ref()
                                .map(|p| format!(" ({})", p))
                                .unwrap_or_default()
                        )
                    }
                    SerialPortType::BluetoothPort => "Bluetooth".to_string(),
                    SerialPortType::PciPort => "PCI".to_string(),
                    SerialPortType::Unknown => "Unknown".to_string(),
                };
                println!("  {} — {}", p.port_name, desc);
            }
        }
        Err(e) => eprintln!("Error listing ports: {}", e),
    }
}

fn auto_detect_port() -> Option<String> {
    let ports = serialport::available_ports().ok()?;
    // Prefer USB serial ports (CH552 bridge shows up as USB)
    ports
        .iter()
        .find(|p| matches!(p.port_type, SerialPortType::UsbPort(_)))
        .map(|p| p.port_name.clone())
}

/// Wrapper to use serial port as a generic reader.
struct PortReader(Box<dyn serialport::SerialPort>);

impl Read for PortReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0.read(buf)
    }
}

/// Read exactly `n` bytes from a reader (serial port or file).
fn read_exact(reader: &mut dyn Read, buf: &mut [u8]) -> std::io::Result<()> {
    let mut offset = 0;
    while offset < buf.len() {
        match reader.read(&mut buf[offset..]) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "end of input",
                ))
            }
            Ok(n) => offset += n,
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// Wait for sync byte, return the packet type byte.
fn wait_for_packet(reader: &mut dyn Read) -> std::io::Result<u8> {
    let mut byte = [0u8; 1];
    loop {
        read_exact(reader, &mut byte)?;
        if byte[0] == SYNC_BYTE {
            read_exact(reader, &mut byte)?;
            return Ok(byte[0]);
        }
    }
}

fn main() {
    let args = Args::parse();

    if args.list_ports {
        list_serial_ports();
        return;
    }

    // Create reader from file or serial port
    let mut reader: Box<dyn Read> = if let Some(ref file_path) = args.file {
        let file = match std::fs::File::open(file_path) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("Failed to open {}: {}", file_path, e);
                std::process::exit(1);
            }
        };
        println!("Reading simulation output from: {}", file_path);
        println!();
        Box::new(std::io::BufReader::new(file))
    } else {
        let port_name = match args.port {
            Some(ref p) => p.clone(),
            None => match auto_detect_port() {
                Some(p) => {
                    println!("Auto-detected port: {}", p);
                    p
                }
                None => {
                    eprintln!("No USB serial port found. Use --port to specify, or --list-ports to see available.");
                    std::process::exit(1);
                }
            },
        };

        let port = match serialport::new(&port_name, args.baud)
            .timeout(Duration::from_secs(10))
            .open()
        {
            Ok(p) => p,
            Err(e) => {
                eprintln!("Failed to open {}: {}", port_name, e);
                std::process::exit(1);
            }
        };

        println!("Connected to {} at {} baud", port_name, args.baud);
        println!("Waiting for device boot...\n");
        Box::new(PortReader(port))
    };

    // ── Phase 1: Receive public key ──
    let verifying_key = loop {
        let pkt_type = match wait_for_packet(&mut *reader) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("Read error while waiting for public key: {}", e);
                std::process::exit(1);
            }
        };

        if pkt_type == PKT_PUBKEY {
            let mut pk_bytes = [0u8; PUBKEY_PAYLOAD];
            if let Err(e) = read_exact(&mut *reader, &mut pk_bytes) {
                eprintln!("Failed to read public key: {}", e);
                std::process::exit(1);
            }

            match VerifyingKey::from_bytes(&pk_bytes) {
                Ok(vk) => {
                    println!("Device public key: {}", hex::encode(pk_bytes));
                    println!();
                    break vk;
                }
                Err(e) => {
                    eprintln!("Invalid public key: {} — retrying...", e);
                    continue;
                }
            }
        }
    };

    // ── Phase 2: Receive and verify signature packets ──
    let mut verified_count: u64 = 0;
    let mut failed_count: u64 = 0;
    let mut dropped_count: u64 = 0;
    let mut last_frame_num: Option<u32> = None;
    let start_time = Instant::now();

    println!("Listening for signed frames...\n");
    println!(
        "{:<8} {:<10} {:<66} {}",
        "Frame", "Status", "Hash (first 32B)", "Sig (first 16B)"
    );
    println!("{}", "-".repeat(110));

    loop {
        let pkt_type = match wait_for_packet(&mut *reader) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                // Normal end-of-file for --file mode
                break;
            }
            Err(e) => {
                eprintln!("\nRead error: {}", e);
                break;
            }
        };

        match pkt_type {
            PKT_PUBKEY => {
                // Device rebooted — re-read public key
                let mut pk_bytes = [0u8; PUBKEY_PAYLOAD];
                if read_exact(&mut *reader, &mut pk_bytes).is_ok() {
                    eprintln!(
                        "\nDevice rebooted! New public key: {}",
                        hex::encode(pk_bytes)
                    );
                }
            }
            PKT_SIGNATURE => {
                let mut payload = [0u8; SIG_PAYLOAD];
                if let Err(e) = read_exact(&mut *reader, &mut payload) {
                    eprintln!("\nFailed to read signature packet: {}", e);
                    continue;
                }

                // Parse packet
                let frame_num =
                    u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
                let hash = &payload[4..68]; // 64 bytes SHA-512 hash
                let sig_bytes = &payload[68..132]; // 64 bytes Ed25519 signature

                // Gap detection: check frame number sequence
                if let Some(last) = last_frame_num {
                    let gap = frame_num.saturating_sub(last + 1);
                    if gap > 0 {
                        dropped_count += gap as u64;
                        eprintln!(
                            "  WARNING: {} dropped frame(s) between {} and {}",
                            gap, last, frame_num
                        );
                    }
                }
                last_frame_num = Some(frame_num);

                // Verify Ed25519 signature
                let signature = match Signature::from_slice(sig_bytes) {
                    Ok(s) => s,
                    Err(_) => {
                        failed_count += 1;
                        println!(
                            "{:<8} {:<10} {} {}",
                            frame_num,
                            "BAD SIG",
                            hex::encode(&hash[..32]),
                            hex::encode(&sig_bytes[..16])
                        );
                        continue;
                    }
                };

                // Reconstruct the signed message: frame_num (4B BE) || hash[0..60]
                // The FPGA signs {frame_num, frame_hash[511:32]} = frame_num + first 60 bytes of hash
                let mut signed_msg = [0u8; 64];
                signed_msg[0..4].copy_from_slice(&payload[0..4]); // frame_num
                signed_msg[4..64].copy_from_slice(&hash[0..60]); // truncated hash

                let valid = verifying_key
                    .verify_strict(&signed_msg, &signature)
                    .is_ok();

                if valid {
                    verified_count += 1;
                    println!(
                        "{:<8} {:<10} {} {}",
                        frame_num,
                        "VERIFIED",
                        hex::encode(&hash[..32]),
                        hex::encode(&sig_bytes[..16])
                    );
                } else {
                    failed_count += 1;
                    println!(
                        "{:<8} {:<10} {} {}",
                        frame_num,
                        "FAILED",
                        hex::encode(&hash[..32]),
                        hex::encode(&sig_bytes[..16])
                    );
                }

                // Periodic summary
                let elapsed = start_time.elapsed().as_secs_f64();
                let total = verified_count + failed_count;
                if total % 100 == 0 && total > 0 {
                    println!(
                        "\n--- {} frames | {} verified | {} failed | {:.1} fps ---\n",
                        total, verified_count, failed_count, total as f64 / elapsed
                    );
                }
            }
            other => {
                eprintln!("Unknown packet type: 0x{:02x}", other);
            }
        }
    }

    // Summary
    let total = verified_count + failed_count;
    let elapsed = start_time.elapsed().as_secs_f64();
    println!("\n=== Session Summary ===");
    println!("Total frames:    {}", total);
    println!("Verified:        {}", verified_count);
    println!("Failed:          {}", failed_count);
    println!("Dropped:         {}", dropped_count);
    println!("Duration:        {:.1}s", elapsed);
    if elapsed > 0.0 {
        println!("Avg framerate:   {:.1} fps", total as f64 / elapsed);
    }
}
