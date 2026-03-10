# Makefile for TEE-camera host runner
#
# Dependencies:
#   - Keystone SDK (C++ host library)
#
# Variables:
#   KEYSTONE_SDK  path to the keystone SDK root  (default: ../keystone/sdk)
#   CROSS_COMPILE RISC-V cross compiler prefix   (default: riscv64-unknown-linux-gnu-)
#
# Targets:
#   host    (default) – build the host binary
#   clean   – remove build artifacts

KEYSTONE_SDK ?= ../keystone/sdk
CROSS_COMPILE ?= riscv64-unknown-linux-gnu-

CXX := $(CROSS_COMPILE)g++
AR  := $(CROSS_COMPILE)ar

# ---- Paths inside the Keystone SDK ----
KEYSTONE_HOST_INCLUDE := $(KEYSTONE_SDK)/include/host
KEYSTONE_INCLUDE      := $(KEYSTONE_SDK)/include
KEYSTONE_LIB_DIR      := $(KEYSTONE_SDK)/lib

# The Keystone host library is typically libkeystone-host.a or libkeystone.a.
# Try libkeystone-host first; fall back to libkeystone.
KEYSTONE_LIB := $(shell \
    if [ -f "$(KEYSTONE_LIB_DIR)/libkeystone-host.a" ]; then \
        echo "keystone-host"; \
    elif [ -f "$(KEYSTONE_LIB_DIR)/libkeystone.a" ]; then \
        echo "keystone"; \
    else \
        echo "keystone-host"; \
    fi)

# ---- Compiler flags ----
CXXFLAGS := \
    -std=c++14 \
    -Wall \
    -Wextra \
    -O2 \
    -I$(KEYSTONE_INCLUDE) \
    -I$(KEYSTONE_HOST_INCLUDE) \
    -I../enclave

LDFLAGS := \
    -L$(KEYSTONE_LIB_DIR) \
    -l$(KEYSTONE_LIB) \
    -lpthread

# ---- Sources ----
SRCS := host.cpp
OBJS := $(SRCS:.cpp=.o)
TARGET := host

# ---- Rules ----
.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

# host.cpp includes ../enclave/common.h
host.o: host.cpp ../enclave/common.h

clean:
	$(RM) $(OBJS) $(TARGET)
