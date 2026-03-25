#!/usr/bin/env python3
"""OV7670 live camera tuner — adjust registers via UART + SCCB bridge."""

import sys
import time
import argparse
import glob
import cv2
import serial

# OV7670 registers for color tuning
REGS = {
    'Red Gain':    0x02,  # RED: red channel gain
    'Green Gain':  0x6A,  # GGAIN: green channel gain
    'Blue Gain':   0x01,  # BLUE: blue channel gain
    'Brightness':  0x55,  # BRIGHT: brightness (signed, 0x00=0, 0x80=-128)
    'Contrast':    0x56,  # CONTRAS: contrast
    'AWB':         0x13,  # COM8: bit1=AWB enable
}

# Defaults (mid-range gains, neutral brightness, default contrast)
DEFAULTS = {
    'Red Gain':   0x40,
    'Green Gain': 0x40,
    'Blue Gain':  0x40,
    'Brightness': 0x00,
    'Contrast':   0x40,
    'AWB':        0,      # 0=off, 1=on
}


def find_serial_port():
    """Find the iCESugar-Pro UART port."""
    patterns = ['/dev/tty.usbmodem*', '/dev/ttyACM*', '/dev/ttyUSB*']
    for pat in patterns:
        ports = sorted(glob.glob(pat))
        if ports:
            return ports[-1]  # last port is usually the UART
    return None


def send_reg(ser, addr, data):
    """Send a 2-byte SCCB write command."""
    ser.write(bytes([addr, data]))
    time.sleep(0.005)  # small delay for SCCB transaction


def on_trackbar(val):
    """Dummy callback — actual sending happens in main loop."""
    pass


def main():
    parser = argparse.ArgumentParser(description='OV7670 Camera Tuner')
    parser.add_argument('--device', type=int, default=0, help='Capture device index')
    parser.add_argument('--port', type=str, default=None, help='Serial port (auto-detect if omitted)')
    parser.add_argument('--baud', type=int, default=9600, help='Baud rate')
    args = parser.parse_args()

    # Find serial port
    port = args.port or find_serial_port()
    if not port:
        print("No serial port found. Use --port to specify.")
        sys.exit(1)
    print(f"Serial: {port} @ {args.baud}")
    ser = serial.Serial(port, args.baud, timeout=0.1)

    # Open capture
    cap = cv2.VideoCapture(args.device)
    if not cap.isOpened():
        print(f"Failed to open device {args.device}")
        sys.exit(1)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

    # Create window with trackbars
    win = 'OV7670 Tuner'
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(win, 800, 600)

    cv2.createTrackbar('Red Gain',   win, DEFAULTS['Red Gain'],   0xFF, on_trackbar)
    cv2.createTrackbar('Green Gain', win, DEFAULTS['Green Gain'], 0xFF, on_trackbar)
    cv2.createTrackbar('Blue Gain',  win, DEFAULTS['Blue Gain'],  0xFF, on_trackbar)
    cv2.createTrackbar('Brightness', win, DEFAULTS['Brightness'], 0xFF, on_trackbar)
    cv2.createTrackbar('Contrast',   win, DEFAULTS['Contrast'],   0xFF, on_trackbar)
    cv2.createTrackbar('AWB',        win, DEFAULTS['AWB'],        1,    on_trackbar)

    # Send initial values
    for name in ['Red Gain', 'Green Gain', 'Blue Gain', 'Brightness', 'Contrast']:
        send_reg(ser, REGS[name], DEFAULTS[name])
    # COM8: 0xE5 = AGC+AEC on, AWB off; 0xE7 = AGC+AEC+AWB on
    send_reg(ser, REGS['AWB'], 0xE5)

    prev = dict(DEFAULTS)
    print("Adjust sliders. Press 'q' to quit, 'p' to print current values.")

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # Check trackbar changes and send register writes
        for name in ['Red Gain', 'Green Gain', 'Blue Gain', 'Brightness', 'Contrast']:
            val = cv2.getTrackbarPos(name, win)
            if val != prev[name]:
                send_reg(ser, REGS[name], val)
                prev[name] = val

        awb = cv2.getTrackbarPos('AWB', win)
        if awb != prev['AWB']:
            send_reg(ser, REGS['AWB'], 0xE7 if awb else 0xE5)
            prev['AWB'] = awb

        # Show color stats overlay
        h, w = frame.shape[:2]
        region = frame[h//4:3*h//4, w//4:3*w//4]
        avg = region.mean(axis=(0, 1))
        info = f"Avg R={avg[2]:.0f} G={avg[1]:.0f} B={avg[0]:.0f}"
        cv2.putText(frame, info, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)

        cv2.imshow(win, frame)
        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('p'):
            print(f"Red={prev['Red Gain']:02X} Green={prev['Green Gain']:02X} "
                  f"Blue={prev['Blue Gain']:02X} Bright={prev['Brightness']:02X} "
                  f"Contrast={prev['Contrast']:02X} AWB={'ON' if prev['AWB'] else 'OFF'}")

    cap.release()
    ser.close()
    cv2.destroyAllWindows()


if __name__ == '__main__':
    main()
