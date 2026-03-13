# TEE-camera Docker build environment (minimal)
#
# Build:  docker build -t tee-camera .
# Run:    docker run -it --rm -v $(pwd)/output:/work/output tee-camera
#
# Uses Alpine (~5MB base) with static binaries for minimal footprint

# ---- Build stage ----
FROM alpine:3.19 AS builder

RUN apk add --no-cache build-base

WORKDIR /work
COPY enclave/*.c enclave/*.h /work/enclave/
COPY tools/*.c /work/tools/
COPY tools/Makefile /work/tools/

# Build static binaries (no runtime dependencies)
RUN cd /work/tools && make CC="gcc -static"

# ---- Runtime stage ----
FROM alpine:3.19

WORKDIR /work
COPY --from=builder /work/tools/generate_test_frames /work/tools/
COPY --from=builder /work/tools/verify_frames /work/tools/

# Create output directory
RUN mkdir -p /work/output/frames

# Default: generate and verify 5 test frames
CMD ["/bin/sh", "-c", "/work/tools/generate_test_frames 5 320 240 /work/output/frames && /work/tools/verify_frames -v /work/output/frames/frame_*.signed"]
