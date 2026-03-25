/* Linker script for PicoRV32 SoC */
MEMORY {
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    RAM (rwx) : ORIGIN = 0x00008000, LENGTH = 8K
}

SECTIONS {
    .text : {
        KEEP(*(.init))
        *(.text*)
        *(.rodata*)
    } > ROM

    .data : {
        *(.data*)
    } > RAM AT > ROM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    _end = .;
}
