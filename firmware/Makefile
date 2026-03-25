# Firmware build for PicoRV32 camera attestation SoC
CROSS = riscv64-elf-
CC = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump

CFLAGS = -march=rv32im -mabi=ilp32 -Os -ffreestanding -nostdlib -fno-builtin -Wall \
         -ffunction-sections -fdata-sections
LDFLAGS = -T link.ld -nostdlib -Wl,--no-relax -Wl,--gc-sections

SRCS = start.S main.c monocypher.c monocypher-ed25519.c libgcc.c
OBJS = $(SRCS:.c=.o)
OBJS := $(OBJS:.S=.o)

all: firmware.hex firmware.dis

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S
	$(CC) $(CFLAGS) -c $< -o $@

firmware.elf: $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

firmware.hex: firmware.bin
	python3 bin2hex.py $< > $@

firmware.dis: firmware.elf
	$(OBJDUMP) -d $< > $@

size: firmware.elf
	$(CROSS)size $<

clean:
	rm -f *.o *.elf *.bin *.hex *.dis

.PHONY: all clean size
