#!/bin/bash
# Build TEE-Camera HDMI host as a macOS .app bundle
# Usage: cd host && ./build_app.sh

set -e

# Install dependencies if needed
pip3 install --quiet opencv-python numpy cryptography pyinstaller

# Build .app bundle
pyinstaller \
    --name "TEE-Camera" \
    --windowed \
    --onefile \
    --noconfirm \
    --add-data "." \
    --hidden-import cv2 \
    --hidden-import numpy \
    --hidden-import cryptography \
    hdmi_host.py

echo ""
echo "=== Built: dist/TEE-Camera.app ==="
echo "Drag it to /Applications or your Dock."
