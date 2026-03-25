.section .init, "ax"
.global _start

_start:
    /* Set stack pointer to top of data RAM */
    li sp, 0x9FFC
    /* Jump to C main */
    j main
