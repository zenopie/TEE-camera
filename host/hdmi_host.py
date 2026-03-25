#!/usr/bin/env python3
"""TEE-Camera HDMI Host — capture video, decode barcode, verify Ed25519 signatures,
   and live-tune OV7670 camera registers via UART→SCCB bridge."""

import sys
import time
import argparse
import glob
import numpy as np
import cv2
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

try:
    import serial
    HAS_SERIAL = True
except ImportError:
    HAS_SERIAL = False

# HDMI frame layout (must match FPGA fpga_top.v)
BLOCK_SIZE = 4
BITS_PER_ROW = 160
BYTES_PER_ROW = 20
DATA_ROWS = 9
TOTAL_DATA_BYTES = 164

# OV7670 tuning registers
CAM_REGS = {
    'Red':        0x02,
    'Green':      0x6A,
    'Blue':       0x01,
    'Brightness': 0x55,
    'Contrast':   0x56,
    'Sharpness':  0x3F,
    'Denoise':    0x4C,
    'AWB':        0x13,
}

CAM_DEFAULTS = {
    'Red':        0x20,
    'Green':      0x20,
    'Blue':       0x20,
    'Brightness': 0x00,
    'Contrast':   0x40,
    'Sharpness':  0x08,
    'Denoise':    0x00,
    'AWB':        1,
}


def find_serial_port():
    """Find the iCESugar-Pro UART port."""
    for pat in ['/dev/tty.usbmodem*', '/dev/ttyACM*', '/dev/ttyUSB*']:
        ports = sorted(glob.glob(pat))
        if ports:
            return ports[-1]
    return None


def send_reg(ser, addr, data):
    """Send a 2-byte SCCB write command."""
    if ser:
        ser.write(bytes([addr, data]))
        time.sleep(0.005)


def find_sync_row(gray):
    """Find sync pattern row (alternating B/W blocks), resolution-aware."""
    h, w = gray.shape
    bsz = max(2, w // 160)
    search_start = int(h * 0.80)
    for y in range(search_start, h - bsz * 6):
        row = gray[y, :]
        n = len(row) // bsz
        if n < 10:
            continue
        blocks = row[:n * bsz].reshape(n, bsz).mean(axis=1)
        high = blocks > 128
        alt = np.sum(high[:-1] != high[1:])
        if alt > n * 0.7:
            return y, bsz
    return None, bsz


def decode_barcode(gray, sync_y, bsz):
    """Decode binary barcode → 164 bytes, resolution-aware."""
    start_y = sync_y + bsz
    data = bytearray()
    for dr in range(DATA_ROWS):
        sy = start_y + dr * bsz + bsz // 2
        if sy >= gray.shape[0]:
            data.extend(b'\x00' * BYTES_PER_ROW)
            continue
        bits = []
        for bc in range(BITS_PER_ROW):
            sx = bc * bsz + bsz // 2
            bits.append(1 if (sx < gray.shape[1] and gray[sy, sx] > 128) else 0)
        for bi in range(BYTES_PER_ROW):
            v = 0
            for bit in range(8):
                v = (v << 1) | bits[bi * 8 + bit]
            data.append(v)
    return bytes(data[:TOTAL_DATA_BYTES])


def verify_signature(pk_bytes, frame_num, frame_hash, signature):
    """Verify Ed25519 signature over (frame_num BE || hash[0:60])."""
    try:
        pk = Ed25519PublicKey.from_public_bytes(pk_bytes)
        msg = frame_num.to_bytes(4, 'big') + frame_hash[:60]
        pk.verify(signature, msg)
        return True
    except (InvalidSignature, ValueError, Exception):
        return False


def on_trackbar(_):
    pass


def main():
    parser = argparse.ArgumentParser(description='TEE-Camera HDMI Host')
    parser.add_argument('--device', type=int, default=0, help='Capture device index')
    parser.add_argument('--port', type=str, default=None, help='Serial port (auto-detect)')
    parser.add_argument('--baud', type=int, default=9600, help='Baud rate')
    parser.add_argument('--no-tuner', action='store_true', help='Disable camera tuning sliders')
    args = parser.parse_args()

    # Serial port for camera tuning
    ser = None
    if not args.no_tuner and HAS_SERIAL:
        port = args.port or find_serial_port()
        if port:
            try:
                ser = serial.Serial(port, args.baud, timeout=0.1)
                print(f"Camera tuning: {port} @ {args.baud}")
            except Exception as e:
                print(f"Serial open failed: {e}")
    if not ser and not args.no_tuner:
        print("No serial port — tuning sliders disabled (install pyserial, connect USB)")

    cap = cv2.VideoCapture(args.device)
    if not cap.isOpened():
        print(f"Failed to open device {args.device}")
        sys.exit(1)

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"Capture: device={args.device}, {w}x{h}")

    # Window
    win = "TEE-Camera Attestation"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)

    # Add tuning sliders if serial available
    tuner_active = ser is not None
    prev_vals = dict(CAM_DEFAULTS)
    if tuner_active:
        cv2.resizeWindow(win, 800, 950)
        cv2.createTrackbar('Red',        win, CAM_DEFAULTS['Red'],        0xFF, on_trackbar)
        cv2.createTrackbar('Green',      win, CAM_DEFAULTS['Green'],      0xFF, on_trackbar)
        cv2.createTrackbar('Blue',       win, CAM_DEFAULTS['Blue'],       0xFF, on_trackbar)
        cv2.createTrackbar('Brightness', win, CAM_DEFAULTS['Brightness'], 0xFF, on_trackbar)
        cv2.createTrackbar('Contrast',   win, CAM_DEFAULTS['Contrast'],   0xFF, on_trackbar)
        cv2.createTrackbar('Sharpness',  win, CAM_DEFAULTS['Sharpness'],  0x1F, on_trackbar)
        cv2.createTrackbar('Denoise',    win, CAM_DEFAULTS['Denoise'],    0xFF, on_trackbar)
        cv2.createTrackbar('AWB',        win, CAM_DEFAULTS['AWB'],        1,    on_trackbar)
        # Send full Linux kernel OV7670 default register set via UART.
        # The FPGA ROM only has 23 registers — the kernel writes 100+.
        # These undocumented/magic regs are critical for proper ISP color.
        # Source: linux/drivers/media/i2c/ov7670.c
        print("Sending full OV7670 register init via UART...")
        kernel_regs = [
            # Gamma curve
            (0x7A, 0x20), (0x7B, 0x10), (0x7C, 0x1E), (0x7D, 0x35),
            (0x7E, 0x5A), (0x7F, 0x69), (0x80, 0x76), (0x81, 0x80),
            (0x82, 0x88), (0x83, 0x8F), (0x84, 0x96), (0x85, 0xA3),
            (0x86, 0xAF), (0x87, 0xC4), (0x88, 0xD7), (0x89, 0xE8),
            # AGC/AEC setup
            (0x13, 0xE0),  # COM8: disable AGC/AEC/AWB temporarily
            (0x00, 0x00), (0x10, 0x00), (0x0D, 0x40),
            (0x14, 0x18),  # COM9: 4x gain ceiling
            (0xA5, 0x05), (0xAB, 0x07),
            (0x24, 0x95), (0x25, 0x33), (0x26, 0xE3),
            (0x9F, 0x78), (0xA0, 0x68), (0xA1, 0x03),
            (0xA6, 0xD8), (0xA7, 0xD8), (0xA8, 0xF0),
            (0xA9, 0x90), (0xAA, 0x94),
            (0x13, 0xE5),  # COM8: AGC+AEC on, AWB off
            # Reserved/magic registers
            (0x0E, 0x61), (0x0F, 0x4B), (0x16, 0x02),
            (0x21, 0x02), (0x22, 0x91), (0x29, 0x07), (0x33, 0x0B),
            (0x35, 0x0B), (0x37, 0x1D), (0x38, 0x71), (0x39, 0x2A),
            (0x3C, 0x78), (0x4D, 0x40), (0x4E, 0x20),
            (0x69, 0x00), (0x6B, 0x4A),
            (0x74, 0x10), (0x8D, 0x4F), (0x8E, 0x00), (0x8F, 0x00),
            (0x90, 0x00), (0x91, 0x00), (0x96, 0x00), (0x9A, 0x00),
            (0xB0, 0x84), (0xB1, 0x0C), (0xB2, 0x0E), (0xB3, 0x82),
            (0xB8, 0x0A),
            # Lens correction
            (0x62, 0x80), (0x63, 0x80), (0x64, 0x06), (0x65, 0x00),
            (0x66, 0x05), (0x94, 0x06), (0x95, 0x08),
            # Color matrix (RGB)
            (0x4F, 0xB3), (0x50, 0xB3), (0x51, 0x00),
            (0x52, 0x3D), (0x53, 0xA7), (0x54, 0xE4), (0x58, 0x9E),
            # Format
            (0x40, 0xD0),  # COM15: RGB565 + full range
            # Enable AWB or not based on slider default
            (0x13, 0xE7 if CAM_DEFAULTS['AWB'] else 0xE5),
            # Manual gains
            (0x02, CAM_DEFAULTS['Red']),
            (0x6A, CAM_DEFAULTS['Green']),
            (0x01, CAM_DEFAULTS['Blue']),
        ]
        for addr, data in kernel_regs:
            send_reg(ser, addr, data)
        print(f"Sent {len(kernel_regs)} registers.")

    last_pubkey = None
    last_frame_num = -1
    verified = 0
    failed = 0
    start = time.time()

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        display = frame.copy()

        if display.shape[0] > 600:
            display = cv2.resize(display, (640, 480))
        panel = np.zeros((180, display.shape[1], 3), dtype=np.uint8)
        display = np.vstack([display, panel])

        status = "NO BARCODE"
        color = (0, 165, 255)

        sync_y, bsz = find_sync_row(gray)
        if sync_y is not None:
            data = decode_barcode(gray, sync_y, bsz)
            pk = data[0:32]
            fn = int.from_bytes(data[32:36], 'big')
            fh = data[36:100]
            sig = data[100:164]

            if not all(b == 0 for b in pk):
                if last_pubkey != pk:
                    last_pubkey = pk
                    print(f"Public key: {pk.hex()}")

                if fn != last_frame_num and fn > 0:
                    last_frame_num = fn
                    if verify_signature(pk, fn, fh, sig):
                        verified += 1
                        status = f"VERIFIED bundle #{fn}"
                        color = (0, 255, 0)
                    else:
                        failed += 1
                        status = f"FAILED bundle #{fn}"
                        color = (0, 0, 255)
                else:
                    status = f"OK bundle #{last_frame_num}" if verified > 0 else "WAITING"
                    color = (0, 200, 0) if verified > 0 else (0, 165, 255)

        # Draw overlay
        dh = display.shape[0]
        dw = display.shape[1]

        cv2.rectangle(display, (0, 0), (dw, 65), (0, 0, 0), -1)
        cv2.putText(display, status, (10, 28),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, color, 2)

        # Color stats
        region = frame[frame.shape[0]//4:3*frame.shape[0]//4,
                       frame.shape[1]//4:3*frame.shape[1]//4]
        avg = region.mean(axis=(0, 1))
        stats = f"OK:{verified} FAIL:{failed}  Avg R={avg[2]:.0f} G={avg[1]:.0f} B={avg[0]:.0f}"
        cv2.putText(display, stats, (10, 55),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1)

        # Bottom data panel
        panel_y = dh - 175
        if sync_y is not None and not all(b == 0 for b in data[:32]):
            pk_hex = data[0:32].hex()
            fn_val = int.from_bytes(data[32:36], 'big')
            hash_hex = data[36:100].hex()
            sig_hex = data[100:164].hex()

            f = cv2.FONT_HERSHEY_PLAIN
            cv2.putText(display, f"PubKey: {pk_hex}", (8, panel_y + 18), f, 1.0, (100, 180, 255), 1)
            cv2.putText(display, f"Bundle: {fn_val}", (8, panel_y + 36), f, 1.0, (200, 200, 200), 1)
            cv2.putText(display, f"Hash:   {hash_hex[:64]}", (8, panel_y + 54), f, 1.0, (200, 200, 100), 1)
            cv2.putText(display, f"        {hash_hex[64:]}", (8, panel_y + 72), f, 1.0, (200, 200, 100), 1)
            cv2.putText(display, f"Sig:    {sig_hex[:64]}", (8, panel_y + 90), f, 1.0, (200, 150, 100), 1)
            cv2.putText(display, f"        {sig_hex[64:]}", (8, panel_y + 108), f, 1.0, (200, 150, 100), 1)
        else:
            cv2.putText(display, "No barcode data decoded", (8, panel_y + 40),
                        cv2.FONT_HERSHEY_PLAIN, 1.2, (120, 120, 120), 1)

        # Handle tuner slider changes
        if tuner_active:
            for name in ['Red', 'Green', 'Blue', 'Brightness', 'Contrast', 'Sharpness', 'Denoise']:
                val = cv2.getTrackbarPos(name, win)
                if val != prev_vals[name]:
                    send_reg(ser, CAM_REGS[name], val)
                    prev_vals[name] = val
            awb = cv2.getTrackbarPos('AWB', win)
            if awb != prev_vals['AWB']:
                send_reg(ser, CAM_REGS['AWB'], 0xE7 if awb else 0xE5)
                prev_vals['AWB'] = awb

        cv2.imshow(win, display)
        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('p') and tuner_active:
            print(f"Red={prev_vals['Red']:02X} Green={prev_vals['Green']:02X} "
                  f"Blue={prev_vals['Blue']:02X} Bright={prev_vals['Brightness']:02X} "
                  f"Contrast={prev_vals['Contrast']:02X} AWB={'ON' if prev_vals['AWB'] else 'OFF'}")

    cap.release()
    if ser:
        ser.close()
    cv2.destroyAllWindows()
    elapsed = time.time() - start
    print(f"\nTotal: {verified+failed} | OK: {verified} | FAIL: {failed} | {elapsed:.1f}s")


if __name__ == '__main__':
    main()
