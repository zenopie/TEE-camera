OUTPUT_ARCH( "riscv" )
ENTRY( EAPP_ENTRY )
SECTIONS
{
  . = 0x0000;
  .text : { *(.text) }
  .rodata : { *(.rodata) }
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
}
